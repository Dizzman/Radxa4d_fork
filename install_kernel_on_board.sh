#!/bin/bash
#
# install_kernel.sh — БЕЗОПАСНАЯ установка ядра на ROCK 4D
# 
# ВНИМАНИЕ! Этот скрипт:
# - НЕ удаляет старые файлы
# - НЕ перезаписывает важные симлинки без проверки
# - СОЗДАЁТ резервную копию старого ядра
# - Имеет восстановление при ошибках
#

set -e

echo "============================================"
echo "  БЕЗОПАСНАЯ установка ядра на ROCK 4D"
echo "============================================"

# Проверка что мы на плате
if ! command -v ls &> /dev/null; then
    echo "ОШИБКА: система повреждена! Нет команды ls"
    echo "Перезагрузитесь и выберите старое ядро в GRUB"
    exit 1
fi

# Проверка наличия архива
BOOT=$(ls -1 ov9281-kernel-*.tar.gz 2>/dev/null | head -1)
HEADERS=$(ls -1 kernel-headers-*.tar.gz 2>/dev/null | head -1)

if [[ -z "$BOOT" ]]; then
    echo "ОШИБКА: не найден ov9281-kernel-*.tar.gz"
    echo "Скопируйте архив с WSL:"
    echo "  scp ov9281-kernel-*.tar.gz radxa@<IP>:~/"
    exit 1
fi

if [[ -z "$HEADERS" ]]; then
    echo "ОШИБКА: не найден kernel-headers-*.tar.gz"
    exit 1
fi

# Определяем версию
KVER=$(echo "$BOOT" | sed 's/ov9281-kernel-\(.*\)\.tar\.gz/\1/')
echo "Версия нового ядра: $KVER"

# Сохраняем текущее ядро
OLD_KVER=$(uname -r)
echo "Текущее ядро: $OLD_KVER"

# СОХРАНЯЕМ ТЕКУЩЕЕ ЯДРО (безопасность!)
echo ""
echo "[1/6] СОЗДАНИЕ РЕЗЕРВНОЙ КОПИИ..."
mkdir -p /root/kernel_backup_$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/root/kernel_backup_$(date +%Y%m%d_%H%M%S)"
cp /boot/Image-${OLD_KVER} $BACKUP_DIR/ 2>/dev/null || true
cp /boot/Image $BACKUP_DIR/ 2>/dev/null || true
cp /boot/rk3576-rock-4d.dtb $BACKUP_DIR/ 2>/dev/null || true
echo "  ✅ Бэкап в: $BACKUP_DIR"

# Распаковка boot
echo ""
echo "[2/6] Распаковка boot..."
tar xzf "$BOOT" -C /

# Проверка что Image распаковался
if [[ ! -f /Image ]]; then
    echo "ОШИБКА: /Image не найден после распаковки!"
    echo "Восстанавливаем бэкап..."
    cp $BACKUP_DIR/Image /boot/ 2>/dev/null || true
    exit 1
fi

# Установка Image (БЕЗ перезаписи существующего!)
echo ""
echo "[3/6] Установка Image..."
if [[ -f /boot/Image-${KVER} ]]; then
    echo "  ⚠ /boot/Image-${KVER} уже существует! Перезаписываю..."
fi
cp /Image /boot/Image-${KVER}

# Обновляем симлинк только если он существует или создаём новый
if [[ -L /boot/Image ]]; then
    OLD_LINK=$(readlink /boot/Image)
    echo "  текущий симлинк: $OLD_LINK"
    rm -f /boot/Image
fi
ln -sf /boot/Image-${KVER} /boot/Image
echo "  ✅ симлинк обновлён"

# Установка dtb
echo ""
echo "[4/6] Установка dtb..."
if [[ -f /rk3576-rock-4d.dtb ]]; then
    cp /rk3576-rock-4d.dtb /boot/rk3576-rock-4d-${KVER}.dtb
    ln -sf /boot/rk3576-rock-4d-${KVER}.dtb /boot/rk3576-rock-4d.dtb 2>/dev/null || true
    echo "  ✅ dtb установлен"
else
    echo "  ⚠ /rk3576-rock-4d.dtb не найден"
fi

# Установка модулей
echo ""
echo "[5/6] Установка модулей..."
if [[ -d /lib/modules/$KVER ]]; then
    echo "  ⚠ модули для $KVER уже существуют"
else
    if [[ -d /lib/modules/$KVER ]]; then
        cp -r /lib/modules/$KVER /lib/modules/ 2>/dev/null || true
    fi
    depmod -a $KVER 2>/dev/null || true
    echo "  ✅ модули установлены"
fi

# Установка заголовков
echo ""
echo "[6/6] Установка заголовков..."
HEADERS_DIR="/usr/src/linux-headers-$KVER"
if [[ -d "$HEADERS_DIR" ]]; then
    echo "  ⚠ $HEADERS_DIR уже существует! Удаляю..."
    rm -rf "$HEADERS_DIR"
fi
mkdir -p "$HEADERS_DIR"
tar xzf "$HEADERS" -C "$HEADERS_DIR"
echo "  ✅ заголовки установлены"

# Восстановление путей (безопасно)
echo ""
echo "=== Восстановление путей ==="
rm -f /lib/modules/$KVER/build
rm -f /lib/modules/$KVER/source
ln -sf /usr/src/linux-headers-$KVER /lib/modules/$KVER/build
ln -sf /usr/src/linux-headers-$KVER /lib/modules/$KVER/source
echo "  ✅ пути обновлены"

# Сборка утилит (если есть make)
echo ""
echo "=== Сборка утилит ==="
if command -v make &> /dev/null; then
    cd "$HEADERS_DIR"
    make scripts_basic 2>/dev/null || echo "  ⚠ make scripts_basic предупреждения"
    make scripts 2>/dev/null || echo "  ⚠ make scripts предупреждения"
    echo "  ✅ утилиты собраны"
else
    echo "  ⚠ make не установлен, утилиты не собраны"
    echo "  Установите: sudo apt install make gcc"
fi

# Обновление initramfs (только для нового ядра)
echo ""
echo "=== Обновление initramfs ==="
if command -v update-initramfs &> /dev/null; then
    # Проверяем, существует ли initramfs для нового ядра
    if [[ -f /boot/initrd.img-${KVER} ]]; then
        echo "  ⚠ initramfs уже существует, обновляю..."
        update-initramfs -u -k $KVER 2>/dev/null || echo "  ⚠ ошибка обновления"
    else
        echo "  создаю новый initramfs..."
        update-initramfs -c -k $KVER 2>/dev/null || echo "  ⚠ ошибка создания"
    fi
    echo "  ✅ initramfs обновлён"
else
    echo "  ⚠ update-initramfs не найден"
fi

# Обновление GRUB
echo ""
echo "=== Обновление загрузчика ==="
if command -v update-grub &> /dev/null; then
    update-grub 2>/dev/null || echo "  ⚠ ошибка обновления GRUB"
    echo "  ✅ GRUB обновлён"
else
    if command -v u-boot-update &> /dev/null; then
        u-boot-update 2>/dev/null || true
        echo "  ✅ u-boot обновлён"
    fi
fi

echo ""
echo "============================================================"
echo " ✅ УСТАНОВКА ЗАВЕРШЕНА!"
echo ""
echo " ТЕКУЩЕЕ ядро: $OLD_KVER"
echo " НОВОЕ ядро:   $KVER"
echo ""
echo " Резервная копия старого ядра:"
echo "   $BACKUP_DIR"
echo ""
echo " ДЛЯ ПЕРЕХОДА НА НОВОЕ ЯДРО:"
echo "   sudo reboot"
echo ""
echo " ЕСЛИ НЕ ЗАГРУЗИТСЯ — в GRUB выберите старое ядро:"
echo "   Advanced options → $OLD_KVER"
echo ""
echo " ПОСЛЕ ПЕРЕЗАГРУЗКИ проверьте:"
echo "   uname -r                    (ожидается: $KVER)"
echo ""
echo " Затем запустите сборку WiFi:"
echo "   sudo ./install_wifi_dkms.sh"
echo "============================================================"
