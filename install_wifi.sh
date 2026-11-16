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
trap 'rc=$?; echo "" >&2; echo "ОШИБКА: install_kernel.sh прерван (код $rc) в строке $LINENO: $BASH_COMMAND" >&2; exit $rc' ERR

run() { echo "+ $*"; "$@"; }
die() { echo "ОШИБКА: $*" >&2; [[ -n "${STAGE:-}" ]] && rm -rf "$STAGE"; exit 1; }

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
echo "✅ vmlinuz-${KVER}"

run mkdir -p "/usr/lib/linux-image-${KVER}/rockchip"
if ls "$STAGE/boot"/rk3576-rock-4d*.dtb &>/dev/null; then
    run cp "$STAGE/boot"/rk3576-rock-4d*.dtb "/usr/lib/linux-image-${KVER}/rockchip/"
    echo "✅ dtb"
else
    echo "⚠  dtb rk3576-rock-4d*.dtb в архиве нет — загрузчик возьмёт dtb по умолчанию"
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
    run dtc -@ -I dts -O dtb -o /tmp/rock-4d-ov9281.dtbo "$STAGE/boot/overlay.dts"
    run mkdir -p /boot/dtbo
    run cp /tmp/rock-4d-ov9281.dtbo /boot/dtbo/rock-4d-ov9281.dtbo
    echo "✅ Overlay установлен: /boot/dtbo/rock-4d-ov9281.dtbo"
    mv /boot/dtbo/rock-4d-rpi-camera-v1_3.dtbo /boot/dtbo/rock-4d-rpi-camera-v1_3.dtbo.disabled 2>/dev/null || true
else
    echo "ОШИБКА: overlay.dts не найден в boot/ — камера работать не будет!"
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
[[ -s "$HEADERS_DIR/Module.symvers" ]] || echo "⚠  $HEADERS_DIR/Module.symvers пустой/отсутствует — WiFi-модуль может не загрузиться"
echo "✅ Заголовки распакованы в $HEADERS_DIR"
echo "   (scripts/ — x86 из WSL; для сборки ДРУГИХ модулей на плате запустите install_wifi.sh, он пересоберёт их)"

run rm -rf "$STAGE"
STAGE=""

echo ""
echo "=== initramfs и загрузчик ==="
if [[ -f "/boot/initrd.img-$KVER" ]]; then
    run update-initramfs -u -k "$KVER"      # уже есть (повторная установка) — обновить
else
    run update-initramfs -c -k "$KVER"      # первая установка — создать
fi
[[ -s "/boot/initrd.img-$KVER" ]] || die "initramfs /boot/initrd.img-$KVER не создан"
echo "✅ initramfs"

# --- Загрузчик: НОВОЕ ЯДРО ПО УМОЛЧАНИЮ --------------------------------------
echo ""
echo "=== Загрузчик: новое ядро $KVER по умолчанию ==="
EXTLINUX=/boot/extlinux/extlinux.conf
UBOOT_CFG=/etc/default/u-boot

# Метка (l0, l1, ...) пункта меню, который грузит vmlinuz-$KVER (не rescue).
# Сравнение строк, без regex — в версии есть '+'.
find_label() {
    awk -v k="vmlinuz-$KVER" '
        $1=="label" { l=$2 }
        $1=="linux" && substr($2, length($2)-length(k)+1)==k && l !~ /r$/ { print l; exit }
    ' "$EXTLINUX"
}
current_default() {
    awk '$1=="default"{print $2; exit}' "$EXTLINUX"
}
show_menu() {
    echo "--- пункты меню $EXTLINUX ---"
    awk '$1=="default"{print "  default " $2} $1=="label"{l=$2} $1=="linux"{print "  " l "\t" $2}' "$EXTLINUX"
    echo "-----------------------------------------------"
}

BOOT_DEFAULT_OK=0
if command -v u-boot-update &>/dev/null; then
    run u-boot-update
    [[ -f "$EXTLINUX" ]] || die "после u-boot-update нет $EXTLINUX"
    LABEL=$(find_label)
    if [[ -z "$LABEL" ]]; then
        show_menu
        die "в $EXTLINUX нет пункта с vmlinuz-$KVER — загрузчик не увидел новое ядро"
    fi
    echo "Новое ядро в меню: пункт '$LABEL'"

    # Где ещё задаётся U_BOOT_DEFAULT (может перебивать /etc/default/u-boot)
    OTHER_DEF=$(grep -rlE '^[[:space:]]*U_BOOT_DEFAULT=' /usr/share/u-boot-menu /etc/u-boot-menu 2>/dev/null || true)
    [[ -n "$OTHER_DEF" ]] && echo "ℹ  U_BOOT_DEFAULT задаётся также в: $OTHER_DEF"

    # Способ 1 (постоянный): U_BOOT_DEFAULT в /etc/default/u-boot
    [[ -f "$UBOOT_CFG" ]] || touch "$UBOOT_CFG"
    run cp "$UBOOT_CFG" "$BACKUP_DIR/u-boot.default"
    if grep -qE '^#?[[:space:]]*U_BOOT_DEFAULT=' "$UBOOT_CFG"; then
        run sed -i -E "s|^#?[[:space:]]*U_BOOT_DEFAULT=.*|U_BOOT_DEFAULT=\"$LABEL\"|" "$UBOOT_CFG"
    else
        echo "U_BOOT_DEFAULT=\"$LABEL\"" >> "$UBOOT_CFG"
    fi
    # Если есть conf.d u-boot-menu — продублируем туда (на образах, где он
    # читается ПОСЛЕ /etc/default/u-boot и перебивает его)
    if [[ -d /usr/share/u-boot-menu/conf.d || -d /etc/u-boot-menu ]]; then
        run mkdir -p /etc/u-boot-menu/conf.d
        echo "U_BOOT_DEFAULT=\"$LABEL\"" > /etc/u-boot-menu/conf.d/99-ov9281-default.conf
    fi
    run u-boot-update

    LABEL=$(find_label)
    DEFAULT=$(current_default)
    if [[ -n "$LABEL" && "$DEFAULT" == "$LABEL" ]]; then
        BOOT_DEFAULT_OK=1
        echo "✅ загрузчик: по умолчанию '$DEFAULT' → vmlinuz-$KVER (через U_BOOT_DEFAULT)"
    else
        # Способ 2 (запасной): прямо правим 'default' в extlinux.conf.
        # Работает сразу, но следующий u-boot-update может вернуть как было.
        echo "⚠  u-boot-update оставил default='$DEFAULT' (нужно '$LABEL') — правлю $EXTLINUX напрямую"
        run cp "$EXTLINUX" "$BACKUP_DIR/extlinux.conf.before"
        if grep -q '^default ' "$EXTLINUX"; then
            run sed -i -E "s|^default .*|default $LABEL|" "$EXTLINUX"
        else
            run sed -i "1i default $LABEL" "$EXTLINUX"
        fi
        DEFAULT=$(current_default)
        if [[ "$DEFAULT" == "$LABEL" ]]; then
            BOOT_DEFAULT_OK=1
            echo "✅ загрузчик: по умолчанию '$DEFAULT' → vmlinuz-$KVER (прямая правка extlinux.conf)"
            echo "   ⚠ после следующего 'u-boot-update' проверьте: grep ^default $EXTLINUX"
        fi
    fi
    show_menu
    echo "   (бэкап /etc/default/u-boot и extlinux.conf: $BACKUP_DIR)"
    [[ "$BOOT_DEFAULT_OK" -eq 1 ]] || die "не удалось выставить $KVER по умолчанию — пришлите вывод выше"
else
    echo "⚠  u-boot-update не найден — ядро по умолчанию НЕ выставлено"
fi

echo ""
echo "============================================================"
echo " УСТАНОВКА ЗАВЕРШЕНА"
echo ""
echo " Архив:          $PKG"
echo " Новое ядро:     $KVER"
echo " OV9281 overlay: /boot/dtbo/rock-4d-ov9281.dtbo"
echo " WiFi AIC8800:   /lib/modules/$KVER/updates/aic8800 (готовые модули)"
echo " Заголовки:      $HEADERS_DIR"
echo ""
if [[ "$BOOT_DEFAULT_OK" -eq 1 ]]; then
    echo " Загрузка:       по умолчанию НОВОЕ ядро ($KVER)"
else
    echo " Загрузка:       ⚠ ядро по умолчанию НЕ выставлено — см. предупреждение выше"
fi
echo " Откат на старое ядро ($OLD_KVER): выбрать его в меню U-Boot при старте"
echo "   или вернуть /etc/default/u-boot из $BACKUP_DIR/u-boot.default и sudo u-boot-update"
echo ""
echo " ДАЛЬШЕ:"
echo "   sudo reboot"
echo "   uname -r                    (ожидается: $KVER)"
echo "   ip -br link                 (должен появиться wl*-интерфейс)"
echo "   nmcli device wifi list"
echo "============================================================"
