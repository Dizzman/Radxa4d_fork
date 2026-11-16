#!/bin/bash
#
# install_kernel.sh — устанавливает на плате ROCK 4D из ОДНОГО архива
# ov9281-<версия>.tar.gz (внутри — подпапки boot/ и headers/):
#   - новое ядро (Image → vmlinuz, modules, dtb) — из boot/
#   - overlay камеры OV9281 (компилирует .dts → .dtbo и устанавливает) — из boot/
#   - распаковывает заголовки (БЕЗ компиляции scripts — это делает
#     отдельный install_wifi.sh, после reboot) — из headers/
#
# Использование:
#   sudo ./install_kernel.sh                         — взять САМЫЙ СВЕЖИЙ подходящий архив
#   sudo ./install_kernel.sh ov9281-<версия>.tar.gz  — взять указанный архив
#
set -e

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
    [[ -n "$PKG" ]] || die "ни один архив не имеет формата boot/+headers/. Пересоберите: ./deploy_ov9281.sh build <ИМЯ> и заново deploy."
    if [[ ${#CANDIDATES[@]} -gt 1 ]]; then
        echo "⚠  Архивов несколько — беру самый свежий подходящий. Старые лучше удалить:"
        echo "     mkdir -p ~/ov9281_old && mv ~/ov9281-*.tar.gz ~/ov9281_old/   (кроме нужного)"
    fi
fi

OLD_KVER=$(uname -r)
echo "Архив:        $PKG ($(du -h "$PKG" | cut -f1), $(date -r "$PKG" '+%Y-%m-%d %H:%M'))"
echo "Текущее ядро: $OLD_KVER"

echo ""
echo "=== [1/6] Зависимости ==="
run apt-get update -qq
run apt-get install -y rsync device-tree-compiler

echo ""
echo "=== [2/6] Распаковка архива ==="
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
echo "✅ Архив распакован, boot/ и headers/ на месте"
echo "Новое ядро:   $KVER"

echo ""
echo "=== [3/6] Резервная копия текущего ядра ==="
BACKUP_DIR="/root/kernel_backup_$(date +%Y%m%d_%H%M%S)"
run mkdir -p "$BACKUP_DIR"
[[ -f /boot/vmlinuz-${OLD_KVER} ]] && run cp /boot/vmlinuz-${OLD_KVER} "$BACKUP_DIR/"
[[ -d /usr/lib/linux-image-${OLD_KVER} ]] && run cp -r /usr/lib/linux-image-${OLD_KVER} "$BACKUP_DIR/"
echo "Бэкап: $BACKUP_DIR"

echo ""
echo "=== [4/6] Установка ядра, dtb, модулей (из boot/) ==="
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
echo "=== [5/6] Overlay камеры OV9281 (из boot/) ==="
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
echo "=== [6/6] Заголовки (из headers/, БЕЗ компиляции — сделает install_wifi.sh) ==="
HEADERS_DIR="/usr/src/linux-headers-$KVER"
run rm -rf "$HEADERS_DIR"
run mkdir -p "$HEADERS_DIR"
run cp -a "$STAGE/headers/." "$HEADERS_DIR/"
run ln -sfn "$HEADERS_DIR" "/lib/modules/${KVER}/build"
run ln -sfn "$HEADERS_DIR" "/lib/modules/${KVER}/source"
[[ -s "$HEADERS_DIR/Module.symvers" ]] || echo "⚠  $HEADERS_DIR/Module.symvers пустой/отсутствует — WiFi-модуль может не загрузиться"
echo "✅ Заголовки распакованы в $HEADERS_DIR"
echo "   (host-инструменты scripts/ пока x86_64 — install_wifi.sh пересоберёт их нативно)"

run rm -rf "$STAGE"
STAGE=""

echo ""
echo "=== initramfs и загрузчик ==="
run update-initramfs -c -k "$KVER"
echo "✅ initramfs"

if command -v u-boot-update &> /dev/null; then
    run u-boot-update
    echo "✅ загрузчик обновлён"
fi

echo ""
echo "============================================================"
echo " УСТАНОВКА ЗАВЕРШЕНА"
echo ""
echo " Архив:          $PKG"
echo " Новое ядро:     $KVER"
echo " OV9281 overlay: /boot/dtbo/rock-4d-ov9281.dtbo"
echo " Заголовки:      $HEADERS_DIR (готовы для install_wifi.sh)"
echo ""
echo " Метку загрузки по умолчанию нужно выставить вручную:"
echo "   grep -B1 'menu label.*$KVER' /boot/extlinux/extlinux.conf"
echo "   sudo sed -i 's/^#\\?U_BOOT_DEFAULT=.*/U_BOOT_DEFAULT=\"<label>\"/' /etc/default/u-boot"
echo "   sudo u-boot-update"
echo ""
echo " ДАЛЬШЕ:"
echo "   sudo reboot"
echo "   uname -r                    (ожидается: $KVER)"
echo "   sudo ./install_wifi.sh      (сборка scripts + WiFi-драйвера НАТИВНО)"
echo "============================================================"
