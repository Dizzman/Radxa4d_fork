#!/bin/bash
#
# install_kernel.sh — устанавливает на плате ROCK 4D:
#   - новое ядро (Image → vmlinuz, modules, dtb)
#   - overlay камеры OV9281 (компилирует .dts → .dtbo и устанавливает)
#   - распаковывает архив заголовков (БЕЗ компиляции scripts — это делает
#     отдельный install_wifi.sh, после reboot)
#
# Использование:
#   sudo ./install_kernel.sh
#
set -e

run() { echo "+ $*"; "$@"; }

echo "============================================================"
echo "  УСТАНОВКА ЯДРА НА ROCK 4D (OV9281, built-in камера)"
echo "============================================================"

BOOT=$(ls -1 ov9281-kernel-*.tar.gz 2>/dev/null | head -1)
HEADERS=$(ls -1 kernel-headers-*.tar.gz 2>/dev/null | head -1)
[[ -z "$BOOT" ]]    && { echo "ОШИБКА: не найден ov9281-kernel-*.tar.gz"; exit 1; }
[[ -z "$HEADERS" ]] && { echo "ОШИБКА: не найден kernel-headers-*.tar.gz"; exit 1; }

KVER=$(echo "$BOOT" | sed 's/ov9281-kernel-\(.*\)\.tar\.gz/\1/')
OLD_KVER=$(uname -r)
echo "Текущее ядро: $OLD_KVER"
echo "Новое ядро:   $KVER"

echo ""
echo "=== [1/6] Зависимости ==="
run sudo apt-get update -qq
run sudo apt-get install -y rsync device-tree-compiler

echo ""
echo "=== [2/6] Резервная копия текущего ядра ==="
BACKUP_DIR="/root/kernel_backup_$(date +%Y%m%d_%H%M%S)"
run mkdir -p "$BACKUP_DIR"
[[ -f /boot/vmlinuz-${OLD_KVER} ]] && run cp /boot/vmlinuz-${OLD_KVER} "$BACKUP_DIR/"
[[ -d /usr/lib/linux-image-${OLD_KVER} ]] && run cp -r /usr/lib/linux-image-${OLD_KVER} "$BACKUP_DIR/"
echo "Бэкап: $BACKUP_DIR"

echo ""
echo "=== [3/6] Установка ядра, dtb, модулей ==="
STAGE=$(mktemp -d)
run tar xzf "$BOOT" -C "$STAGE"
[[ -f "$STAGE/Image" ]] || { echo "ОШИБКА: Image не найден внутри архива"; rm -rf "$STAGE"; exit 1; }

run sudo cp "$STAGE/Image" "/boot/vmlinuz-${KVER}"
echo "✅ vmlinuz-${KVER}"

run sudo mkdir -p "/usr/lib/linux-image-${KVER}/rockchip"
sudo cp "$STAGE"/rk3576-rock-4d*.dtb "/usr/lib/linux-image-${KVER}/rockchip/" 2>/dev/null || true
echo "✅ dtb"

run sudo mkdir -p "/lib/modules/${KVER}"
run sudo rsync -a "$STAGE/lib/modules/${KVER}/" "/lib/modules/${KVER}/"
run sudo depmod -a "$KVER"
echo "✅ модули"

run sudo cp "$STAGE/config-plain" "/boot/config-${KVER}"

echo ""
echo "=== [4/6] Overlay камеры OV9281 ==="
if [[ -f "$STAGE/overlay.dts" ]]; then
    run sudo dtc -@ -I dts -O dtb -o /tmp/rock-4d-ov9281.dtbo "$STAGE/overlay.dts"
    run sudo mkdir -p /boot/dtbo
    run sudo cp /tmp/rock-4d-ov9281.dtbo /boot/dtbo/rock-4d-ov9281.dtbo
    echo "✅ Overlay установлен: /boot/dtbo/rock-4d-ov9281.dtbo"
    sudo mv /boot/dtbo/rock-4d-rpi-camera-v1_3.dtbo /boot/dtbo/rock-4d-rpi-camera-v1_3.dtbo.disabled 2>/dev/null || true
else
    echo "ОШИБКА: overlay.dts не найден в архиве — камера работать не будет!"
fi

if [[ -f "$STAGE/live_auto_exposure.cpp" ]]; then
    run sudo cp "$STAGE/live_auto_exposure.cpp" /usr/local/bin/
    echo "✅ live_auto_exposure.cpp скопирован в /usr/local/bin/"
fi

run rm -rf "$STAGE"

echo ""
echo "=== [5/6] Распаковка заголовков (БЕЗ компиляции — это сделает install_wifi.sh) ==="
HEADERS_DIR="/usr/src/linux-headers-$KVER"
run sudo rm -rf "$HEADERS_DIR"
run sudo mkdir -p "$HEADERS_DIR"
run sudo tar xzf "$HEADERS" -C "$HEADERS_DIR"
run sudo rm -f "/lib/modules/${KVER}/build" "/lib/modules/${KVER}/source"
run sudo ln -sfn "$HEADERS_DIR" "/lib/modules/${KVER}/build"
run sudo ln -sfn "$HEADERS_DIR" "/lib/modules/${KVER}/source"
echo "✅ Заголовки распакованы в $HEADERS_DIR"
echo "   (host-инструменты scripts/ пока x86_64 — install_wifi.sh пересоберёт их нативно)"

echo ""
echo "=== [6/6] initramfs и загрузчик ==="
run sudo update-initramfs -c -k "$KVER"
echo "✅ initramfs"

if command -v u-boot-update &> /dev/null; then
    run sudo u-boot-update
    echo "✅ загрузчик обновлён"
fi

echo ""
echo "============================================================"
echo " УСТАНОВКА ЗАВЕРШЕНА"
echo ""
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
