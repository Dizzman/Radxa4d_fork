#!/bin/bash
#
# install_wifi_from_existing.sh
#
# Устанавливает AIC8800 WiFi на НОВОЕ (только что установленное) ядро без
# пересборки/DKMS/заголовков — копированием уже собранного модуля с
# ТЕКУЩЕГО (штатного, уже работающего) ядра платы и принудительной
# загрузкой через modprobe --force-vermagic.
#
# Почему это безопасно: оба ядра — одна база 6.1.84.x, отличаются только
# несколькими опциями конфига (built-in камера, выключенный KASAN),
# которые не затрагивают ABI cfg80211/mac80211/usbcore. Настоящая
# пересборка через DKMS на плате упиралась в цепочку проблем
# (host-инструменты x86/ARM, tools/be_byteshift.h, зацикливание
# modules_prepare) — не стоящую усилий, раз есть уже рабочий модуль.
#
# Запускать ПОСЛЕ install_kernel.sh и reboot в новое ядро.
#
# Использование:
#   sudo ./install_wifi_from_existing.sh
#
set -uo pipefail

log()  { echo -e "[$(date '+%H:%M:%S')] $*"; }
err()  { echo -e "[$(date '+%H:%M:%S')] ОШИБКА: $*" >&2; }
die()  { err "$*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Запустите через sudo."

KVER=$(uname -r)
log "== WiFi (AIC8800) для ядра $KVER — копирование готового модуля =="

# ---------------------------------------------------------------------------
# 1. Найти уже собранный модуль под ЛЮБЫМ ДРУГИМ установленным ядром
# ---------------------------------------------------------------------------
FOUND_KO=$(find /lib/modules -path "/lib/modules/$KVER" -prune -o \
    -iname "aic8800_fdrv*.ko*" -print 2>/dev/null | head -1)
[[ -n "$FOUND_KO" ]] || die "Не найден уже собранный aic8800_fdrv*.ko(.xz) ни под одним другим установленным ядром. Установите пакет aic8800-usb-dkms хотя бы под одно ядро (обычно уже стоит в штатном образе Radxa)."

log "Найден готовый модуль: $FOUND_KO"
SRCDIR=$(dirname "$FOUND_KO")

# ---------------------------------------------------------------------------
# 2. Скопировать все связанные модули (fdrv, load_fw, btusb) в новое ядро
# ---------------------------------------------------------------------------
DESTDIR="/lib/modules/$KVER/extra"
mkdir -p "$DESTDIR"

COPIED=0
for f in "$SRCDIR"/aic8800_fdrv*.ko* "$SRCDIR"/aic_load_fw*.ko* "$SRCDIR"/aic_btusb*.ko* "$SRCDIR"/aic_bluetooth*.ko*; do
    [[ -e "$f" ]] || continue
    base=$(basename "$f")
    cp "$f" "$DESTDIR/"
    if [[ "$base" == *.xz ]]; then
        xz -d -f "$DESTDIR/$base"
    fi
    COPIED=1
done
[[ "$COPIED" -eq 1 ]] || die "Не удалось скопировать ни одного модуля из $SRCDIR."

log "Модули скопированы в $DESTDIR:"
ls -la "$DESTDIR"

depmod -a "$KVER"

# ---------------------------------------------------------------------------
# 3. Загрузка модулей — cfg80211/mac80211 из СВОЕГО ядра (vermagic
# совпадает, обычная загрузка), aic8800_fdrv — принудительно
# (--force-vermagic/--force-modversion, потому что собран под другое
# ядро; ABI совместим, проверка версии — единственное препятствие)
# ---------------------------------------------------------------------------
log "Загрузка базовых модулей..."
modprobe cfg80211
modprobe mac80211

WIFI_MOD=$(find "$DESTDIR" -iname "aic8800_fdrv*.ko" -printf "%f\n" 2>/dev/null | head -1 | sed 's/\.ko$//')
[[ -n "$WIFI_MOD" ]] || die "Не нашёл распакованный aic8800_fdrv*.ko в $DESTDIR."

log "Загрузка $WIFI_MOD (принудительно, --force-vermagic)..."
if modprobe --force-vermagic --force-modversion "$WIFI_MOD"; then
    log "modprobe $WIFI_MOD — успешно."
else
    die "modprobe $WIFI_MOD не удался — смотрите: sudo dmesg | tail -40"
fi

# ---------------------------------------------------------------------------
# 4. Автозагрузка при следующей перезагрузке — modules-load.d не умеет
# передавать --force-vermagic, поэтому используем systemd-сервис.
# ---------------------------------------------------------------------------
cat > /etc/systemd/system/aic8800-wifi.service << UNIT_EOF
[Unit]
Description=Load AIC8800 WiFi driver (forced vermagic, cross-kernel-version module)
After=local-fs.target
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/modprobe cfg80211
ExecStart=/sbin/modprobe mac80211
ExecStart=/sbin/modprobe --force-vermagic --force-modversion $WIFI_MOD

[Install]
WantedBy=multi-user.target
UNIT_EOF
systemctl daemon-reload
systemctl enable aic8800-wifi.service
log "Автозагрузка настроена: /etc/systemd/system/aic8800-wifi.service"

# ---------------------------------------------------------------------------
# 5. Проверка
# ---------------------------------------------------------------------------
log "== Проверка =="
lsmod | grep -i aic8800 || err "Модуль не виден в lsmod — что-то пошло не так."

echo ""
echo "============================================================"
if ip link show | grep -q "wlan0"; then
    echo " wlan0 обнаружен — WiFi готов к использованию."
else
    echo " wlan0 пока не появился сразу. Причины и что делать:"
    echo ""
    echo " 1. Подождите несколько секунд (загрузка прошивки в чип) и"
    echo "    проверьте снова:"
    echo "      ip link show"
    echo ""
    echo " 2. Если в dmesg видно 'cmd queue crashed' / 'bin upload fail' —"
    echo "    USB-устройство застряло в состоянии от прошлой попытки."
    echo "    Программный сброс порта (без физического переподключения):"
    echo ""
    echo "      for f in /sys/bus/usb/devices/*/idVendor; do"
    echo "          grep -q a69c \"\$f\" 2>/dev/null && dirname \"\$f\"; done"
    echo "      # подставьте найденный путь вместо <PATH>:"
    echo "      echo 0 | sudo tee <PATH>/authorized"
    echo "      sleep 2"
    echo "      echo 1 | sudo tee <PATH>/authorized"
    echo ""
    echo " 3. Если ничего не помогло — перезагрузите плату:"
    echo "      sudo reboot"
fi
echo "============================================================"

echo ""
echo "ip link show:"
ip link show
