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

[[ $EUID -eq 0 ]] || err "Запустите через sudo."

KVER=$(uname -r)
HEADERS_DIR="/usr/src/linux-headers-$KVER"

# Версия официального релиза aic8800-usb-dkms с GitHub Releases.
# ЗАКРЕПЛЕНА 4.x — именно она собралась и заработала на этой плате.
AIC8800_RELEASE_TAG="4.0%2Bgit20250410.b99ca8b6-3"
AIC8800_RELEASE_VER="4.0+git20250410.b99ca8b6-3"
DKMS_NAME="aic8800-usb"
DKMS_ID="${DKMS_NAME}/${AIC8800_RELEASE_VER}"
AIC8800_URL="https://github.com/radxa-pkg/aic8800/releases/download/${AIC8800_RELEASE_TAG}"

echo "============================================================"
echo "  УСТАНОВКА WiFi (AIC8800) — ядро: $KVER"
echo "============================================================"

[[ -d "$HEADERS_DIR" ]] || err "$HEADERS_DIR не найден. Сначала: sudo ./install_kernel.sh и sudo reboot (в новое ядро)."
[[ -s "$HEADERS_DIR/Module.symvers" ]] || err "$HEADERS_DIR/Module.symvers пустой/отсутствует — модуль не загрузится. Пересоберите и переустановите ядро."

# ---------------------------------------------------------------------------
# 1. СБОРКА SCRIPTS (host-инструменты нативно под ARM)
# ---------------------------------------------------------------------------
echo ""
echo "################################################################"
echo "###  [1/3] СБОРКА SCRIPTS (нативно под ARM)"
echo "################################################################"
echo ""

log "Установка зависимостей сборки..."
run apt-get update -qq
run apt-get install -y flex bison build-essential libssl-dev libelf-dev bc device-tree-compiler file wget dkms

# Убираем переменные, которые могут увести make в режим внешнего модуля/кросс-сборки
unset KBUILD_EXTMOD SUBDIRS M KBUILD_SRC O CROSS_COMPILE ARCH || true

run cd "$HEADERS_DIR"

# ВАЖНО: НЕ делаем "make clean" — он удаляет Module.symvers, и тогда
# модуль собирается без версий символов и не грузится.
# Чистим ТОЛЬКО scripts/ и tools/ — там лежат x86-объекты и бинарники из WSL.
log "Удаление x86-64 объектов/бинарников из scripts/ и tools/ (остались от WSL)..."
find scripts tools -type f \( -name "*.o" -o -name ".*.cmd" -o -name "*.a" \) -delete 2>/dev/null || true
find scripts tools -type f -executable -print0 2>/dev/null \
    | xargs -0 -r file 2>/dev/null | grep "x86-64" | cut -d: -f1 | xargs -r rm -f || true
ok "x86-64 файлы удалены"

log "Синхронизация конфига..."
run make olddefconfig

log "Сборка scripts (нативно)..."
run make scripts_basic
run make scripts
# genksyms нужен для CONFIG_MODVERSIONS (раньше его приходилось собирать руками)
if grep -q "^CONFIG_MODVERSIONS=y" .config; then
    run make scripts/genksyms/
fi

log "Проверка, что инструменты собраны под ARM:"
TOOLS="scripts/basic/fixdep scripts/mod/modpost scripts/kconfig/conf"
grep -q "^CONFIG_MODVERSIONS=y" .config && TOOLS="$TOOLS scripts/genksyms/genksyms"
for bin in $TOOLS; do
    [[ -f "$bin" ]] || run make "$bin"
    [[ -f "$bin" ]] || err "$bin не собран"
    if file "$bin" | grep -qiE "aarch64|ARM"; then
        ok "$bin — ARM64"
    else
        file "$bin"
        err "$bin не ARM64-бинарник"
    fi
done

touch modules.order modules.builtin

# ---------------------------------------------------------------------------
# 2. УСТАНОВКА ДРАЙВЕРА (официальный .deb + DKMS)
# ---------------------------------------------------------------------------
echo ""
echo "################################################################"
echo "###  [2/3] УСТАНОВКА ДРАЙВЕРА (aic8800-usb-dkms, официальный .deb)"
echo "################################################################"
echo ""

run cd /tmp
DKMS_DEB="/tmp/aic8800-usb-dkms_${AIC8800_RELEASE_VER}_all.deb"
FW_DEB="/tmp/aic8800-firmware_${AIC8800_RELEASE_VER}_all.deb"

log "Скачивание пакетов (версия $AIC8800_RELEASE_VER)..."
run wget -q -O "$DKMS_DEB" "${AIC8800_URL}/aic8800-usb-dkms_${AIC8800_RELEASE_VER}_all.deb"
run wget -q -O "$FW_DEB"   "${AIC8800_URL}/aic8800-firmware_${AIC8800_RELEASE_VER}_all.deb"

# Убираем из DKMS все ДРУГИЕ версии aic8800-usb (например 5.x), чтобы
# не было конфликта и не загрузился не тот модуль.
log "Удаление из DKMS других версий $DKMS_NAME (кроме $AIC8800_RELEASE_VER)..."
if [[ -d "/var/lib/dkms/$DKMS_NAME" ]]; then
    for d in /var/lib/dkms/$DKMS_NAME/*/; do
        v=$(basename "$d")
        [[ "$v" == "kernel-"* || "$v" == "*" ]] && continue
        if [[ "$v" != "$AIC8800_RELEASE_VER" ]]; then
            warn "Найдена другая версия: $DKMS_NAME/$v — удаляю"
            dkms remove "$DKMS_NAME/$v" --all || true
        fi
    done
fi

log "Установка пакетов $AIC8800_RELEASE_VER (dpkg сам запустит DKMS-сборку против $HEADERS_DIR)..."
# --force-downgrade — на случай, если ранее был поставлен 5.x
if ! run dpkg -i --force-downgrade "$FW_DEB" "$DKMS_DEB"; then
    log "Ошибка установки, пробуем исправить зависимости..."
    run apt-get install -f -y
    run dpkg -i --force-downgrade "$FW_DEB" "$DKMS_DEB"
fi

# Чтобы apt upgrade не обновил драйвер обратно до 5.x
run apt-mark hold aic8800-usb-dkms aic8800-firmware || true

log "Статус DKMS:"
dkms status
if ! dkms status "$DKMS_ID" -k "$KVER" 2>/dev/null | grep -q "installed"; then
    warn "DKMS не показывает $DKMS_ID как installed для $KVER — собираю явно"
    dkms install "$DKMS_ID" -k "$KVER" || {
        tail -n 40 "/var/lib/dkms/${DKMS_ID}/build/make.log" 2>/dev/null || true
        err "dkms install $DKMS_ID не удался (лог выше)"
    }
fi
run depmod -a "$KVER"

log "Проверка версии установленных пакетов и модуля:"
INST_VER=$(dpkg-query -W -f='${Version}' aic8800-usb-dkms 2>/dev/null || echo "нет")
[[ "$INST_VER" == "$AIC8800_RELEASE_VER" ]] \
    && ok "aic8800-usb-dkms: $INST_VER" \
    || err "Установлена версия aic8800-usb-dkms '$INST_VER', ожидалась $AIC8800_RELEASE_VER"
MODFILE=$(modinfo -k "$KVER" -n aic8800_fdrv_usb 2>/dev/null || true)
[[ -n "$MODFILE" ]] || err "модуль aic8800_fdrv_usb не найден для ядра $KVER"
ok "Модуль: $MODFILE"
OTHERS=$(ls -1 "/var/lib/dkms/$DKMS_NAME" 2>/dev/null | grep -v "^kernel-" | grep -vxF "$AIC8800_RELEASE_VER" || true)
[[ -z "$OTHERS" ]] && ok "В DKMS только $DKMS_ID" || warn "В DKMS остались другие версии: $OTHERS"

# ---------------------------------------------------------------------------
# 3. ЗАГРУЗКА МОДУЛЕЙ + автозагрузка
# ---------------------------------------------------------------------------
echo ""
echo "################################################################"
echo "###  [3/3] ЗАГРУЗКА МОДУЛЕЙ"
echo "################################################################"
echo ""

for m in aic_load_fw_usb aic8800_fdrv_usb aic_btusb_usb; do
    run modprobe "$m" || warn "Не удалось загрузить $m"
done

log "Автозагрузка при старте: /etc/modules-load.d/aic8800.conf"
printf "aic_load_fw_usb\naic8800_fdrv_usb\naic_btusb_usb\n" > /etc/modules-load.d/aic8800.conf

sleep 3
echo ""
log "Загруженные модули:"
lsmod | grep -i aic || warn "Ни один aic*-модуль не виден в lsmod"

echo ""
log "Сетевые интерфейсы:"
ip -br link || true

WLAN=$(ls /sys/class/net | grep -E '^wl' | head -1 || true)
echo ""
echo "============================================================"
if [[ -n "$WLAN" ]]; then
    ok "$WLAN обнаружен — WiFi готов к использованию."
    echo ""
    echo "  sudo nmcli device wifi rescan"
    echo "  nmcli device wifi list"
    echo "  sudo nmcli device wifi connect \"<SSID>\" password \"<пароль>\""
else
    warn "WiFi-интерфейс пока не появился."
    echo ""
    echo "1. Подождите несколько секунд (загрузка прошивки):  ip -br link"
    echo "2. dmesg | grep -iE 'aic|firmware' | tail -40"
    echo "3. Если видно 'cmd queue crashed' — сброс USB-порта:"
    echo "   for f in /sys/bus/usb/devices/*/idVendor; do"
    echo "       grep -q a69c \"\$f\" 2>/dev/null && dirname \"\$f\"; done"
    echo "   echo 0 | sudo tee <НАЙДЕННЫЙ_ПУТЬ>/authorized; sleep 2"
    echo "   echo 1 | sudo tee <НАЙДЕННЫЙ_ПУТЬ>/authorized"
fi
echo "============================================================"
