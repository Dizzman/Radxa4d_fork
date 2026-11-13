#!/usr/bin/env bash
# install_build_deps.sh
# Установка всех зависимостей для сборки ядра Radxa 4D с драйвером OV9281
# в WSL/Linux. Запускать от пользователя с sudo-правами.
#
# Использование:
#   chmod +x install_build_deps.sh
#   ./install_build_deps.sh

set -euo pipefail

echo "==> Обновление списка пакетов"
sudo apt update

echo "==> Установка инструментов сборки и зависимостей ядра"
sudo apt install -y \
    build-essential \
    gcc \
    g++ \
    make \
    bc \
    bison \
    flex \
    libssl-dev \
    libelf-dev \
    libncurses-dev \
    dwarves \
    pahole \
    python3 \
    python3-pip \
    git \
    wget \
    curl \
    xz-utils \
    tar \
    rsync \
    kmod \
    cpio \
    device-tree-compiler

echo "==> Установка кросс-компилятора для arm64"
sudo apt install -y \
    gcc-aarch64-linux-gnu \
    g++-aarch64-linux-gnu \
    binutils-aarch64-linux-gnu

# ---------------------------------------------------------------------------
# Отдельная явная проверка и установка libssl-dev
# (на случай, если пакет отсутствовал или был удалён)
# ---------------------------------------------------------------------------
echo "==> Проверка libssl-dev"
if [ -f /usr/include/openssl/ssl.h ] && dpkg -s libssl-dev >/dev/null 2>&1; then
    echo "  OK: libssl-dev уже установлен"
else
    echo "  libssl-dev не найден — устанавливаю..."
    sudo apt install -y libssl-dev
fi

if [ -f /usr/include/openssl/ssl.h ]; then
    echo "  OK: libssl-dev (openssl/ssl.h найден)"
else
    echo "  ОШИБКА: заголовки OpenSSL не найдены после установки" >&2
    exit 1
fi
# ---------------------------------------------------------------------------

echo "==> Проверка ключевых инструментов"
for tool in make gcc bison flex aarch64-linux-gnu-gcc dtc; do
    if command -v "$tool" >/dev/null 2>&1; then
        printf '  OK: %-28s %s\n' "$tool" "$(command -v "$tool")"
    else
        printf '  ОШИБКА: %s не найден\n' "$tool" >&2
        exit 1
    fi
done

# Проверка, что flex и bison реально запускаются от текущего пользователя
# (защита от проблемы Permission denied)
echo "==> Проверка запуска flex и bison от текущего пользователя"
flex --version >/dev/null 2>&1 || { echo "  ОШИБКА: flex не запускается (проверьте права: ls -l \$(which flex))" >&2; exit 1; }
bison --version >/dev/null 2>&1 || { echo "  ОШИБКА: bison не запускается (проверьте права: ls -l \$(which bison))" >&2; exit 1; }
echo "  OK: flex и bison запускаются"

echo
echo "==> Все зависимости установлены и проверены."
echo "    Дальнейшие шаги:"
echo "      1) Получить .config с платы:"
echo "         ssh radxa@<IP> \"zcat /proc/config.gz\" > .config"
echo "      2) Включить драйвер OV9281:"
echo "         ./scripts/config --file .config --enable CONFIG_VIDEO_OV9281"
echo "      3) Синхронизировать конфиг:"
echo "         make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig"
echo "      4) Собрать:"
echo "         ./build_wsl_ov9281.sh build"