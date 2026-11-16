#!/bin/bash
#
# install_kernel.sh — устанавливает на плате ROCK 4D из ОДНОГО архива
# ov9281-<версия>.tar.gz (внутри — подпапки boot/ и headers/):
#   - новое ядро (Image → vmlinuz, modules, dtb) — из boot/
#   - overlay камеры OV9281 (компилирует .dts → .dtbo и устанавливает) — из boot/
#   - WiFi-драйвер AIC8800 4.0 — ОТДЕЛЬНЫЙ ШАГ [5/7]: готовые .ko в
#     /lib/modules/<версия>/updates/aic8800, прошивка в /lib/firmware/aic8800_fw/USB,
#     автозагрузка в /etc/modules-load.d/aic8800.conf, проверка modinfo
#   - распаковывает заголовки — из headers/
#
# Использование:
#   sudo ./install_kernel.sh                         — взять САМЫЙ СВЕЖИЙ подходящий архив
#   sudo ./install_kernel.sh ov9281-<версия>.tar.gz  — взять указанный архив
#
set -e
set -E
NEW_KERNEL_COPIED=0
on_err() {
    local rc=$1 line=$2 cmd=$3
    echo "" >&2
    echo "ОШИБКА: install_kernel.sh прерван (код $rc) в строке $line: $cmd" >&2
    if [[ "$NEW_KERNEL_COPIED" -eq 1 ]] && declare -F pin_boot_default &>/dev/null; then
        echo "→ установка не завершена: закрепляю загрузку СТАРОГО ядра $OLD_KVER" >&2
        pin_boot_default "$OLD_KVER" >&2 || true
    fi
    exit "$rc"
}
trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR

run() { echo "+ $*"; "$@"; }
# Ошибки, которые не прерывают установку сразу, но ЗАПРЕЩАЮТ делать новое
# ядро загрузочным по умолчанию.
ERRORS=()
add_err() { ERRORS+=("$*"); echo "❌ $*" >&2; }

die() {
    echo "ОШИБКА: $*" >&2
    [[ -n "${STAGE:-}" ]] && rm -rf "$STAGE"
    # Если уже начали ставить новое ядро — закрепить загрузку старого
    [[ "${NEW_KERNEL_COPIED:-0}" -eq 1 ]] && declare -F pin_boot_default &>/dev/null && \
        { echo "→ закрепляю загрузку СТАРОГО ядра $OLD_KVER" >&2; pin_boot_default "$OLD_KVER" >&2 || true; }
    exit 1
}

# ---------------- загрузчик (u-boot-menu / extlinux) ----------------
EXTLINUX=/boot/extlinux/extlinux.conf
UBOOT_CFG=/etc/default/u-boot

# Метка (l0, l1, ...) пункта меню с vmlinuz-<версия> (не rescue).
# Сравнение строк, без regex — в версии бывает '+'.
find_label() {
    [[ -f "$EXTLINUX" ]] || return 0
    awk -v k="vmlinuz-$1" '
        $1=="label" { l=$2 }
        $1=="linux" && substr($2, length($2)-length(k)+1)==k && l !~ /r$/ { print l; exit }
    ' "$EXTLINUX"
}
current_default() { [[ -f "$EXTLINUX" ]] && awk '$1=="default"{print $2; exit}' "$EXTLINUX"; }
show_menu() {
    echo "--- меню загрузки $EXTLINUX ---"
    awk '$1=="default"{print "  default " $2} $1=="label"{l=$2} $1=="linux"{print "  " l "\t" $2}' "$EXTLINUX"
    echo "-------------------------------------------"
}

# pin_boot_default <версия> — сделать пункт с этой версией загрузочным по
# умолчанию и ПРОВЕРИТЬ. 0 = выставлено и проверено.
pin_boot_default() {
    local ver="$1" label def
    command -v u-boot-update &>/dev/null || { echo "⚠  u-boot-update не найден"; return 1; }
    u-boot-update >/dev/null
    label=$(find_label "$ver")
    [[ -n "$label" ]] || { echo "⚠  в $EXTLINUX нет пункта с vmlinuz-$ver"; return 1; }

    # Способ 1 (постоянный): U_BOOT_DEFAULT
    [[ -f "$UBOOT_CFG" ]] || touch "$UBOOT_CFG"
    if grep -qE '^#?[[:space:]]*U_BOOT_DEFAULT=' "$UBOOT_CFG"; then
        sed -i -E "s|^#?[[:space:]]*U_BOOT_DEFAULT=.*|U_BOOT_DEFAULT=\"$label\"|" "$UBOOT_CFG"
    else
        echo "U_BOOT_DEFAULT=\"$label\"" >> "$UBOOT_CFG"
    fi
    if [[ -d /usr/share/u-boot-menu/conf.d || -d /etc/u-boot-menu ]]; then
        mkdir -p /etc/u-boot-menu/conf.d
        echo "U_BOOT_DEFAULT=\"$label\"" > /etc/u-boot-menu/conf.d/99-ov9281-default.conf
    fi
    u-boot-update >/dev/null
    label=$(find_label "$ver"); def=$(current_default)
    if [[ -n "$label" && "$def" == "$label" ]]; then
        echo "✅ по умолчанию '$def' → vmlinuz-$ver (U_BOOT_DEFAULT)"
        return 0
    fi

    # Способ 2 (запасной): прямая правка строки default
    echo "⚠  u-boot-update оставил default='$def' (нужно '$label') — правлю $EXTLINUX напрямую"
    if grep -q '^default ' "$EXTLINUX"; then
        sed -i -E "s|^default .*|default $label|" "$EXTLINUX"
    else
        sed -i "1i default $label" "$EXTLINUX"
    fi
    def=$(current_default)
    if [[ "$def" == "$label" ]]; then
        echo "✅ по умолчанию '$def' → vmlinuz-$ver (прямая правка; после следующего u-boot-update проверьте: grep ^default $EXTLINUX)"
        return 0
    fi
    echo "⚠  не удалось выставить default='$label' (сейчас '$def')"
    return 1
}

[[ $EUID -eq 0 ]] || die "Запустите через sudo: sudo $0 $*"

echo "============================================================"
echo "  УСТАНОВКА ЯДРА НА ROCK 4D (OV9281, built-in камера)"
echo "============================================================"

# Проверка, что архив имеет НОВУЮ раскладку (boot/Image + headers/).
# Листинг пишем во временный файл, а не в пайп с grep -q — иначе tar может
# получить SIGPIPE и ложно "упасть".
is_new_layout() {
    local f="$1" lst
    lst=$(mktemp)
    if ! tar tzf "$f" > "$lst" 2>/dev/null; then rm -f "$lst"; return 1; fi
    if grep -qE '^(\./)?boot/Image$' "$lst" && grep -qE '^(\./)?headers/kernel\.release$' "$lst"; then
        rm -f "$lst"; return 0
    fi
    rm -f "$lst"; return 1
}

# --- Выбор архива ---------------------------------------------------------
PKG=""
if [[ -n "${1:-}" ]]; then
    [[ -f "$1" ]] || die "Архив $1 не найден"
    is_new_layout "$1" || die "$1 — архив СТАРОГО формата или битый (нет boot/Image и headers/kernel.release внутри)"
    PKG="$1"
else
    echo "Архивы ov9281-*.tar.gz в $(pwd) (новые сверху):"
    # ls -t — по времени изменения, самый свежий первым
    mapfile -t CANDIDATES < <(ls -1t ov9281-*.tar.gz 2>/dev/null || true)
    [[ ${#CANDIDATES[@]} -gt 0 ]] || die "не найден ни один ov9281-*.tar.gz в $(pwd)"
    for f in "${CANDIDATES[@]}"; do
        if is_new_layout "$f"; then
            echo "   [OK]     $f"
            [[ -z "$PKG" ]] && PKG="$f"
        else
            echo "   [СТАРЫЙ] $f  — нет boot/+headers/, пропускаю"
        fi
    done
    [[ -n "$PKG" ]] || die "ни один архив не имеет формата boot/+headers/. Пересоберите: ./full_deploy_ov9281.sh build <ИМЯ> и заново deploy."
    if [[ ${#CANDIDATES[@]} -gt 1 ]]; then
        echo "⚠  Архивов несколько — беру самый свежий подходящий. Старые лучше удалить:"
        echo "     mkdir -p ~/ov9281_old && mv ~/ov9281-*.tar.gz ~/ov9281_old/   (кроме нужного)"
    fi
fi

OLD_KVER=$(uname -r)
echo "Архив:        $PKG ($(du -h "$PKG" | cut -f1), $(date -r "$PKG" '+%Y-%m-%d %H:%M'))"
echo "Текущее ядро: $OLD_KVER"

echo ""
echo "=== [1/7] Зависимости ==="
run apt-get update -qq
run apt-get install -y rsync device-tree-compiler

echo ""
echo "=== [2/7] Распаковка архива ==="
STAGE=$(mktemp -d)
run tar xzf "$PKG" -C "$STAGE"
if [[ ! -d "$STAGE/boot" || ! -d "$STAGE/headers" || ! -f "$STAGE/boot/Image" ]]; then
    echo "Содержимое архива (первые 20 строк):"
    tar tzf "$PKG" 2>/dev/null | head -20 || true
    die "в $PKG нет boot/Image или headers/"
fi

# Версию ядра берём ИЗ АРХИВА (папка модулей), а не из имени файла.
mapfile -t MODDIRS < <(ls -1 "$STAGE/boot/lib/modules" 2>/dev/null)
[[ ${#MODDIRS[@]} -eq 1 ]] || die "в boot/lib/modules/ ожидается ровно одна папка версии, найдено: ${MODDIRS[*]:-ничего}"
KVER="${MODDIRS[0]}"
if [[ -f "$STAGE/headers/kernel.release" ]]; then
    HKVER=$(cat "$STAGE/headers/kernel.release")
    [[ "$HKVER" == "$KVER" ]] || die "версии не совпадают: модули=$KVER, headers=$HKVER"
fi
for need in "boot/lib/modules/${KVER}/updates/aic8800/aic_load_fw_usb.ko" \
            "boot/lib/modules/${KVER}/updates/aic8800/aic8800_fdrv_usb.ko" \
            "boot/lib/modules/${KVER}/updates/aic8800/aic_btusb_usb.ko" \
            "boot/firmware/aic8800_fw/USB" "boot/aic8800.conf"; do
    [[ -e "$STAGE/$need" ]] || die "в архиве нет $need — WiFi не установится. Пересоберите: ./full_deploy_ov9281.sh build <ИМЯ> (или wifi)"
done
echo "✅ Архив распакован, boot/ и headers/ на месте"
echo "✅ WiFi AIC8800 в архиве: модули + прошивка + автозагрузка"
echo "Новое ядро:   $KVER"

echo ""
echo "=== [3/7] Резервная копия текущего ядра ==="
BACKUP_DIR="/root/kernel_backup_$(date +%Y%m%d_%H%M%S)"
run mkdir -p "$BACKUP_DIR"
[[ -f /boot/vmlinuz-${OLD_KVER} ]] && run cp /boot/vmlinuz-${OLD_KVER} "$BACKUP_DIR/"
[[ -d /usr/lib/linux-image-${OLD_KVER} ]] && run cp -r /usr/lib/linux-image-${OLD_KVER} "$BACKUP_DIR/"
echo "Бэкап: $BACKUP_DIR"

echo ""
echo "=== [4/7] Установка ядра, dtb, модулей (из boot/) ==="
run cp "$STAGE/boot/Image" "/boot/vmlinuz-${KVER}"
NEW_KERNEL_COPIED=1
echo "✅ vmlinuz-${KVER}"

run mkdir -p "/usr/lib/linux-image-${KVER}/rockchip"
if ls "$STAGE/boot"/rk3576-rock-4d*.dtb &>/dev/null; then
    run cp "$STAGE/boot"/rk3576-rock-4d*.dtb "/usr/lib/linux-image-${KVER}/rockchip/"
    echo "✅ dtb"
else
    add_err "dtb rk3576-rock-4d*.dtb нет в архиве"
fi

run mkdir -p "/lib/modules/${KVER}"
run rsync -a "$STAGE/boot/lib/modules/${KVER}/" "/lib/modules/${KVER}/"
# build/source из WSL указывают в никуда — уберём сразу, ниже поставим правильные
run rm -f "/lib/modules/${KVER}/build" "/lib/modules/${KVER}/source"
run depmod -a "$KVER"
echo "✅ модули"

run cp "$STAGE/boot/config-plain" "/boot/config-${KVER}"

echo ""
echo "=== [5/7] Установка WiFi-драйвера AIC8800 (готовые модули из архива, БЕЗ компиляции) ==="
WIFI_MOD_DIR="/lib/modules/${KVER}/updates/aic8800"

# 5.1 Модули: кладём явно (rsync выше их уже скопировал — повторяем, чтобы
#     шаг был самодостаточным и не зависел от содержимого boot/lib/modules)
run mkdir -p "$WIFI_MOD_DIR"
run cp "$STAGE/boot/lib/modules/${KVER}/updates/aic8800/"*.ko "$WIFI_MOD_DIR/"
# Старые DKMS-копии того же драйвера для этого ядра — убрать, чтобы не было дублей
rm -f /lib/modules/${KVER}/updates/dkms/aic*_usb.ko* 2>/dev/null || true

# 5.2 Прошивка
run mkdir -p /lib/firmware/aic8800_fw/USB
run rsync -a "$STAGE/boot/firmware/aic8800_fw/USB/" /lib/firmware/aic8800_fw/USB/

# 5.3 Автозагрузка при старте
run cp "$STAGE/boot/aic8800.conf" /etc/modules-load.d/aic8800.conf

run depmod -a "$KVER"

# 5.4 Проверка
for m in aic_load_fw_usb aic8800_fdrv_usb aic_btusb_usb; do
    f=$(modinfo -k "$KVER" -n "$m" 2>/dev/null || true)
    [[ -n "$f" ]] || die "WiFi: модуль $m не виден для ядра $KVER после depmod"
    vm=$(modinfo -k "$KVER" -F vermagic "$m" 2>/dev/null | awk '{print $1}' || true)
    [[ "$vm" == "$KVER" ]] || die "WiFi: $m собран для '$vm', а ядро $KVER"
    echo "✅ $m → $f"
done
FW_COUNT=$(find /lib/firmware/aic8800_fw/USB -type f | wc -l)
[[ "$FW_COUNT" -gt 0 ]] || die "WiFi: прошивка /lib/firmware/aic8800_fw/USB пуста"
echo "✅ прошивка: /lib/firmware/aic8800_fw/USB ($FW_COUNT файлов)"
echo "✅ автозагрузка: /etc/modules-load.d/aic8800.conf ($(tr '\n' ' ' < /etc/modules-load.d/aic8800.conf))"

if dpkg -s aic8800-usb-dkms &>/dev/null; then
    echo "⚠  Установлен пакет aic8800-usb-dkms — он больше не нужен и может мешать. Удалить:"
    echo "     sudo apt-mark unhold aic8800-usb-dkms; sudo dpkg -r aic8800-usb-dkms"
fi
echo "✅ WiFi AIC8800 установлен — заработает после reboot в $KVER"

echo ""
echo "=== [6/7] Overlay камеры OV9281 (из boot/) ==="
if [[ -f "$STAGE/boot/overlay.dts" ]]; then
    if run dtc -@ -I dts -O dtb -o /tmp/rock-4d-ov9281.dtbo "$STAGE/boot/overlay.dts"; then
        run mkdir -p /boot/dtbo
        run cp /tmp/rock-4d-ov9281.dtbo /boot/dtbo/rock-4d-ov9281.dtbo
        echo "✅ Overlay установлен: /boot/dtbo/rock-4d-ov9281.dtbo"
        mv /boot/dtbo/rock-4d-rpi-camera-v1_3.dtbo /boot/dtbo/rock-4d-rpi-camera-v1_3.dtbo.disabled 2>/dev/null || true
    else
        add_err "dtc не смог скомпилировать overlay.dts"
    fi
else
    add_err "overlay.dts не найден в архиве — камера работать не будет"
fi

if [[ -f "$STAGE/boot/live_auto_exposure.cpp" ]]; then
    run cp "$STAGE/boot/live_auto_exposure.cpp" /usr/local/bin/
    echo "✅ live_auto_exposure.cpp скопирован в /usr/local/bin/"
fi

echo ""
echo "=== [7/7] Заголовки (из headers/) ==="
HEADERS_DIR="/usr/src/linux-headers-$KVER"
run rm -rf "$HEADERS_DIR"
run mkdir -p "$HEADERS_DIR"
run cp -a "$STAGE/headers/." "$HEADERS_DIR/"
run ln -sfn "$HEADERS_DIR" "/lib/modules/${KVER}/build"
run ln -sfn "$HEADERS_DIR" "/lib/modules/${KVER}/source"
[[ -s "$HEADERS_DIR/Module.symvers" ]] || echo "⚠  $HEADERS_DIR/Module.symvers пустой/отсутствует (нужен только для сборки других модулей на плате)"
echo "✅ Заголовки распакованы в $HEADERS_DIR"
echo "   (scripts/ — x86 из WSL; для сборки ДРУГИХ модулей на плате запустите install_wifi.sh, он пересоберёт их)"

run rm -rf "$STAGE"
STAGE=""

echo ""
echo "=== initramfs ==="
if [[ -f "/boot/initrd.img-$KVER" ]]; then
    INITRD_CMD=(update-initramfs -u -k "$KVER")   # уже есть (повторная установка) — обновить
else
    INITRD_CMD=(update-initramfs -c -k "$KVER")   # первая установка — создать
fi
if run "${INITRD_CMD[@]}"; then
    echo "✅ initramfs"
else
    add_err "update-initramfs завершился с ошибкой"
fi

# --- ИТОГОВАЯ ПРОВЕРКА установленного ------------------------------------------
echo ""
echo "=== Проверка установки $KVER ==="
chk() {   # chk "<описание>" <команда...>
    local what="$1"; shift
    if "$@" &>/dev/null; then echo "✅ $what"; else add_err "$what — НЕ OK"; fi
}
chk "ядро /boot/vmlinuz-$KVER"                  test -s "/boot/vmlinuz-$KVER"
chk "initramfs /boot/initrd.img-$KVER"          test -s "/boot/initrd.img-$KVER"
chk "модули /lib/modules/$KVER/modules.dep"     test -s "/lib/modules/$KVER/modules.dep"
chk "dtb rk3576-rock-4d.dtb"                    test -s "/usr/lib/linux-image-$KVER/rockchip/rk3576-rock-4d.dtb"
chk "overlay /boot/dtbo/rock-4d-ov9281.dtbo"    test -s /boot/dtbo/rock-4d-ov9281.dtbo
for m in aic_load_fw_usb aic8800_fdrv_usb aic_btusb_usb; do
    chk "WiFi-модуль $m виден для $KVER"        modinfo -k "$KVER" -n "$m"
done
chk "прошивка /lib/firmware/aic8800_fw/USB"     test -n "$(ls -A /lib/firmware/aic8800_fw/USB 2>/dev/null)"
chk "автозагрузка /etc/modules-load.d/aic8800.conf" test -s /etc/modules-load.d/aic8800.conf

# --- Загрузчик: default ТОЛЬКО при отсутствии ошибок ---------------------------
echo ""
echo "=== Загрузчик ==="
run cp "$UBOOT_CFG" "$BACKUP_DIR/u-boot.default" 2>/dev/null || true
run cp "$EXTLINUX" "$BACKUP_DIR/extlinux.conf.before" 2>/dev/null || true

BOOT_RESULT=""
if [[ ${#ERRORS[@]} -eq 0 ]]; then
    echo "Ошибок нет → делаю НОВОЕ ядро $KVER загрузочным по умолчанию"
    if pin_boot_default "$KVER"; then
        BOOT_RESULT="NEW"
    else
        add_err "не удалось выставить $KVER по умолчанию"
    fi
fi
if [[ "$BOOT_RESULT" != "NEW" ]]; then
    echo "Есть ошибки → новое ядро НЕ делаю загрузочным, закрепляю СТАРОЕ $OLD_KVER"
    if pin_boot_default "$OLD_KVER"; then BOOT_RESULT="OLD"; else BOOT_RESULT="UNKNOWN"; fi
fi
[[ -f "$EXTLINUX" ]] && show_menu
echo "   (бэкап загрузчика: $BACKUP_DIR)"

echo ""
echo "============================================================"
[[ ${#ERRORS[@]} -eq 0 ]] && echo " УСТАНОВКА ЗАВЕРШЕНА — ОШИБОК НЕТ" || echo " УСТАНОВКА ЗАВЕРШЕНА С ОШИБКАМИ — новое ядро НЕ выбрано по умолчанию"
echo ""
echo " Архив:          $PKG"
echo " Новое ядро:     $KVER"
echo " OV9281 overlay: /boot/dtbo/rock-4d-ov9281.dtbo"
echo " WiFi AIC8800:   /lib/modules/$KVER/updates/aic8800 (готовые модули)"
echo " Заголовки:      $HEADERS_DIR"
echo ""
case "$BOOT_RESULT" in
    NEW) echo " Загрузка:       ✅ по умолчанию НОВОЕ ядро ($KVER)" ;;
    OLD) echo " Загрузка:       ⚠ по умолчанию оставлено СТАРОЕ ядро ($OLD_KVER) из-за ошибок" ;;
    *)   echo " Загрузка:       ❌ не удалось проверить ядро по умолчанию — см. вывод выше" ;;
esac
if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo ""
    echo " ОШИБКИ (${#ERRORS[@]}):"
    for e in "${ERRORS[@]}"; do echo "   ❌ $e"; done
    echo " Исправьте и запустите install_kernel.sh снова."
fi
echo " Откат на старое ядро ($OLD_KVER): выбрать его в меню U-Boot при старте"
echo "   или вернуть /etc/default/u-boot из $BACKUP_DIR/u-boot.default и sudo u-boot-update"
echo ""
if [[ "$BOOT_RESULT" == "NEW" ]]; then
    echo " ДАЛЬШЕ:"
    echo "   sudo reboot"
    echo "   uname -r                    (ожидается: $KVER)"
    echo "   ip -br link                 (должен появиться wl*-интерфейс)"
    echo "   nmcli device wifi list"
else
    echo " Перезагрузка сейчас загрузит СТАРОЕ ядро $OLD_KVER (безопасно)."
fi
echo "============================================================"
[[ ${#ERRORS[@]} -eq 0 ]] || exit 2
