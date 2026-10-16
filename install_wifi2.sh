#!/bin/bash
#
# install_wifi.sh — установка WiFi (AIC8800) на плате ROCK 4D.
# Запускать ПОСЛЕ install_kernel.sh и "sudo reboot" в новое ядро.
#

set -uo pipefail
set -e

run() { echo "+ $*"; "$@"; }
log() { echo "[$(date '+%H:%M:%S')] $*"; }
err() { echo "[$(date '+%H:%M:%S')] ОШИБКА: $*" >&2; exit 1; }
ok()  { echo "[$(date '+%H:%M:%S')] ✅ $*"; }
warn(){ echo "[$(date '+%H:%M:%S')] ⚠  $*" >&2; }

[[ $EUID -eq 0 ]] || { err "Запустите через sudo."; }

KVER=$(uname -r)
HEADERS_DIR="/usr/src/linux-headers-$KVER"

# Версия официального релиза aic8800-usb-dkms с GitHub Releases.
AIC8800_RELEASE_TAG="5.0%2Bgit20260123.5f7be68d-6"
AIC8800_RELEASE_VER="5.0+git20260123.5f7be68d-6"

echo "============================================================"
echo "  УСТАНОВКА WiFi (AIC8800) — ядро: $KVER"
echo "============================================================"

[[ -d "$HEADERS_DIR" ]] || { err "$HEADERS_DIR не найден. Сначала: sudo ./install_kernel.sh и sudo reboot."; }

# ---------------------------------------------------------------------------
# 1. СБОРКА SCRIPTS (host-инструменты нативно под ARM)
# ---------------------------------------------------------------------------
echo ""
echo "################################################################"
echo "###  [1/2] СБОРКА SCRIPTS (нативно под ARM)"
echo "################################################################"
echo ""

log "Установка зависимостей сборки..."
run apt-get update -qq
run apt-get install -y flex bison build-essential libssl-dev libelf-dev bc device-tree-compiler

log "Переход в $HEADERS_DIR"
run cd "$HEADERS_DIR"

# Очистка от старых бинарников
log "Очистка старых файлов..."
run make clean 2>/dev/null || true
find . -name "*.o" -delete 2>/dev/null || true
find . -name "*.cmd" -delete 2>/dev/null || true
find . -name "*.d" -delete 2>/dev/null || true
find . -name "*.a" -delete 2>/dev/null || true
find . -name "*.mod" -delete 2>/dev/null || true
find . -name "*.ko" -delete 2>/dev/null || true

log "Удаление x86-64 бинарников, доставшихся из WSL..."
find . -type f -executable -exec file {} \; 2>/dev/null | grep "x86-64" | cut -d: -f1 | xargs rm -f 2>/dev/null || true
ok "x86-64 бинарники удалены"

# Синхронизация конфига
log "Синхронизация конфига..."
run make olddefconfig

# КРИТИЧЕСКИ ВАЖНО: Убираем переменные, которые могут вызвать рекурсию
log "Очистка переменных окружения, влияющих на сборку..."
unset KBUILD_EXTMOD
unset SUBDIRS
unset M
unset KBUILD_SRC
unset O
unset CROSS_COMPILE

# Сборка scripts по частям, избегая рекурсии
log "Сборка scripts (пошагово, без make prepare)..."
log "Шаг 1: Сборка fixdep..."
run make -C "$HEADERS_DIR" scripts/basic/fixdep

log "Шаг 2: Сборка modpost..."
run make -C "$HEADERS_DIR" scripts/mod/modpost

log "Шаг 3: Сборка kconfig/conf..."
run make -C "$HEADERS_DIR" scripts/kconfig/conf

log "Шаг 4: Сборка остальных скриптов..."
run make -C "$HEADERS_DIR" scripts_basic

log "Шаг 5: Сборка модульных скриптов..."
run make -C "$HEADERS_DIR" scripts

# Проверяем, что все необходимые файлы для DKMS существуют
log "Создание необходимых файлов для DKMS..."
touch "$HEADERS_DIR/Module.symvers" 2>/dev/null || true
touch "$HEADERS_DIR/modules.builtin" 2>/dev/null || true
touch "$HEADERS_DIR/modules.order" 2>/dev/null || true

# Создаем .config если его нет
if [ ! -f "$HEADERS_DIR/.config" ]; then
    log "Создание .config..."
    make -C "$HEADERS_DIR" defconfig 2>/dev/null || true
    make -C "$HEADERS_DIR" olddefconfig 2>/dev/null || true
fi

log "Проверка, что всё собралось для ARM:"
for bin in scripts/basic/fixdep scripts/mod/modpost scripts/kconfig/conf; do
    if [ -f "$bin" ]; then
        echo "=== $bin ==="
        file "$bin"
        if file "$bin" 2>/dev/null | grep -qiE "ARM aarch64|ELF 64-bit LSB.*ARM"; then
            ok "$bin — ARM64"
        else
            warn "$bin не ARM64-бинарник, пересборка..."
            rm -f "$bin"
            make -C "$HEADERS_DIR" "$bin"
        fi
    else
        err "$bin не найден"
    fi
done

# ---------------------------------------------------------------------------
# 2. УСТАНОВКА ДРАЙВЕРА (официальный .deb + DKMS)
# ---------------------------------------------------------------------------
echo ""
echo "################################################################"
echo "###  [2/2] УСТАНОВКА ДРАЙВЕРА (aic8800-usb-dkms, официальный .deb)"
echo "################################################################"
echo ""

log "Переход в /tmp"
run cd /tmp

log "Скачивание пакетов (версия $AIC8800_RELEASE_VER)..."
run wget -q "https://github.com/radxa-pkg/aic8800/releases/download/${AIC8800_RELEASE_TAG}/aic8800-usb-dkms_${AIC8800_RELEASE_VER}_all.deb"
run wget -q "https://github.com/radxa-pkg/aic8800/releases/download/${AIC8800_RELEASE_TAG}/aic8800-firmware_${AIC8800_RELEASE_VER}_all.deb"

log "Установка пакетов (dpkg сам запустит DKMS-сборку против $HEADERS_DIR)..."
run dpkg -i /tmp/aic8800-usb-dkms_*.deb /tmp/aic8800-firmware_*.deb || {
    log "Установка завершилась с ошибкой, пробуем исправить зависимости..."
    apt-get install -f -y
    run dpkg -i /tmp/aic8800-usb-dkms_*.deb /tmp/aic8800-firmware_*.deb
}

# Проверяем статус DKMS
log "Проверка статуса DKMS..."
dkms status

log "Загрузка модулей..."
run modprobe aic8800_fdrv_usb 2>/dev/null || warn "Не удалось загрузить aic8800_fdrv_usb"
run modprobe aic_load_fw_usb 2>/dev/null || warn "Не удалось загрузить aic_load_fw_usb"
run modprobe aic_btusb_usb 2>/dev/null || warn "Не удалось загрузить aic_btusb_usb"

echo ""
log "Проверка загруженных модулей:"
lsmod | grep -i aic || warn "Ни один aic*-модуль не виден в lsmod"

echo ""
log "Проверка сетевых интерфейсов:"
ip link show | grep -E "(wlan|eth|lo)" || warn "Интерфейсы не найдены"

echo ""
echo "============================================================"
if ip link show wlan0 &>/dev/null; then
    ok "wlan0 обнаружен — WiFi готов к использованию."
    echo ""
    echo "Для поднятия интерфейса:"
    echo "  sudo ip link set wlan0 up"
    echo "  sudo iw dev wlan0 scan | grep SSID"
else
    warn "wlan0 пока не появился."
    echo ""
    echo "Возможные причины и что делать:"
    echo "1. Подождите несколько секунд (загрузка прошивки в чип):"
    echo "   ip link show"
    echo ""
    echo "2. Проверьте dmesg на ошибки прошивки/USB:"
    echo "   dmesg | tail -40"
    echo ""
    echo "3. Если видно 'cmd queue crashed' / устройство зависло —"
    echo "   программный сброс USB-порта (без физического отключения):"
    echo "   for f in /sys/bus/usb/devices/*/idVendor; do"
    echo "       grep -q a69c \"\$f\" 2>/dev/null && dirname \"\$f\"; done"
    echo "   echo 0 | sudo tee <НАЙДЕННЫЙ_ПУТЬ>/authorized"
    echo "   sleep 2"
    echo "   echo 1 | sudo tee <НАЙДЕННЫЙ_ПУТЬ>/authorized"
    
    echo ""
    echo "4. Проверка логов:"
    echo "   dmesg | grep -i aic8800"
    echo "   dmesg | grep -i firmware"
    echo "   dmesg | grep -i usb | tail -20"
    echo "   dmesg | grep -i wifi"
fi
echo "============================================================"
