#!/bin/bash
#
# install_wifi_dkms.sh
#
# Надёжная (пере)сборка и загрузка драйвера AIC8800 WiFi через DKMS под
# ТЕКУЩЕЕ запущенное ядро платы. Инкапсулирует все проблемы, реально
# встреченные в ходе отладки:
#
#   - пакет aic8800-usb-dkms может оказаться в состоянии 'hold'
#     (apt-mark hold) после предыдущих экспериментов — снимается;
#   - /usr/src/linux-headers-<KVER>, поставляемый обычным apt-пакетом
#     или собранный вручную, может НЕ совпадать по .config с реально
#     запущенным ядром — тогда нужны headers именно от той сборки
#     (см. deploy_ov9281.sh / install_kernel.sh);
#   - CONFIG_KASAN=y в .config ядра ломает сборку модуля — проверяется;
#   - дерево headers может быть неполным на уровне scripts/mod/modpost
#     (например, если кто-то вручную копировал только часть scripts/) —
#     скрипт сам пытается исправить это через 'make modules_prepare',
#     а НЕ через 'make scripts' (последний требует полного tools/,
#     включая tools/be_byteshift.h, которого в headers-пакете нет и
#     не должно быть — это тянет за собой scripts/sorttable, не нужный
#     для сборки внешних модулей);
#   - старые built-in .ko того же имени в
#     kernel/drivers/net/wireless/aic8800/ могут конфликтовать с
#     версией, установленной DKMS, — при явном обнаружении спрашивается,
#     удалить ли их;
#   - несовпадение vermagic между собранным модулем и запущенным ядром
#     проявляется как "disagrees about version of symbol ..." в dmesg —
#     после загрузки сверяется явно.
#
# Использование:
#   ./install_wifi_dkms.sh
#
set -uo pipefail

log()  { echo -e "[$(date '+%H:%M:%S')] $*"; }
err()  { echo -e "[$(date '+%H:%M:%S')] ОШИБКА: $*" >&2; }
warn() { echo -e "[$(date '+%H:%M:%S')] ВНИМАНИЕ: $*" >&2; }
die()  { err "$*"; exit 1; }

KVER=$(uname -r)
log "Текущее ядро: $KVER"

# ---------------------------------------------------------------------------
# 1. dkms.conf: имя и версия модуля
# ---------------------------------------------------------------------------
DKMS_STATUS=$(sudo dkms status 2>/dev/null | grep -i "aic8800" | grep -v "^aic8800/1.0:" || true)
if [[ -z "$DKMS_STATUS" ]]; then
    die "Ни одна версия aic8800-usb не зарегистрирована в DKMS (sudo dkms status). Установите пакет/репозиторий драйвера сначала."
fi

MOD_NAME=$(echo "$DKMS_STATUS" | head -1 | cut -d/ -f1)
MOD_VER=$(echo "$DKMS_STATUS" | head -1 | cut -d/ -f2 | cut -d, -f1)
log "Модуль DKMS: $MOD_NAME/$MOD_VER"

# ---------------------------------------------------------------------------
# 2. Снятие hold, если пакет заморожен
# ---------------------------------------------------------------------------
HOLD_STATE=$(dpkg -l 2>/dev/null | awk '/aic8800-usb-dkms/{print $1}')
if [[ "$HOLD_STATE" == "hi" ]]; then
    warn "Пакет aic8800-usb-dkms в состоянии 'hold' — снимаю."
    sudo apt-mark unhold aic8800-usb-dkms
fi

# ---------------------------------------------------------------------------
# 3. Проверка headers для текущего ядра
# ---------------------------------------------------------------------------
BUILD_LINK="/lib/modules/$KVER/build"
if [[ ! -e "$BUILD_LINK" ]]; then
    die "$BUILD_LINK не существует. Нет заголовков для текущего ядра $KVER. Установите их (см. install_kernel_on_board.sh, если это кастомная сборка)."
fi

BUILD_REAL=$(readlink -f "$BUILD_LINK")
log "Заголовки ядра: $BUILD_REAL"

if [[ ! -f "$BUILD_REAL/Makefile" ]]; then
    err "$BUILD_REAL/Makefile не найден напрямую в этом каталоге."
    err "Похоже, headers-архив был распакован с лишним уровнем вложенности"
    err "(например, .../linux-headers-$KVER/headers_$KVER/Makefile вместо"
    err ".../linux-headers-$KVER/Makefile). Проверьте:"
    err "  find $BUILD_REAL -maxdepth 2 -iname Makefile"
    die "Останавливаюсь — сборка DKMS не сможет найти дерево ядра."
fi

if [[ -f "$BUILD_REAL/.config" ]]; then
    RUNNING_MD5=$(zcat /proc/config.gz 2>/dev/null | md5sum | cut -d' ' -f1 || echo "")
    HEADERS_MD5=$(md5sum "$BUILD_REAL/.config" | cut -d' ' -f1)
    if [[ -n "$RUNNING_MD5" && "$RUNNING_MD5" != "$HEADERS_MD5" ]]; then
        warn ".config запущенного ядра (md5 $RUNNING_MD5) НЕ совпадает"
        warn "с .config в $BUILD_REAL/.config (md5 $HEADERS_MD5)."
        warn "Это тот самый сценарий, который раньше давал 'disagrees about"
        warn "version of symbol' при загрузке модуля. Возможные причины:"
        warn "  - /proc/config.gz недоступен в этом ядре (CONFIG_IKCONFIG_PROC=n)"
        warn "  - headers реально относятся к другой сборке"
        warn "Продолжаю, но будьте готовы к несовпадению vermagic ниже."
    else
        log "Конфигурация headers совпадает с запущенным ядром (OK)."
    fi

    if grep -q "^CONFIG_KASAN=y" "$BUILD_REAL/.config"; then
        die "CONFIG_KASAN=y в .config текущих headers — сборка WiFi-модуля не удастся. Пересоберите ядро с выключенным CONFIG_KASAN."
    fi
fi

if [[ -f "$BUILD_REAL/scripts/mod/modpost" ]]; then
    log "scripts/mod/modpost присутствует (OK)."
else
    warn "scripts/mod/modpost отсутствует — дерево headers, похоже, неполное."
    log "Пробую 'make modules_prepare' (не 'make scripts' — тот тянет"
    log "полный tools/, который в headers-пакете обычно не нужен и не поставляется)."
    if ( cd "$BUILD_REAL" && sudo make ARCH=arm64 modules_prepare ); then
        log "modules_prepare выполнен успешно."
    else
        die "modules_prepare завершился ошибкой. Дерево $BUILD_REAL, похоже,"\
" неполное (нет Makefile/scripts верхнего уровня, или архив был упакован"\
" с лишним уровнем вложенности — проверьте, что $BUILD_REAL/Makefile"\
" существует напрямую, а не в подкаталоге)."
    fi
fi

if [[ -f "$BUILD_REAL/scripts/module.lds" ]] && grep -q '\.plt' "$BUILD_REAL/scripts/module.lds"; then
    log "scripts/module.lds с секциями .plt — на месте (OK)."
else
    warn "scripts/module.lds отсутствует или без секций .plt — возможна ошибка"
    warn "'module PLT section(s) missing' при сборке на arm64."
fi

# ---------------------------------------------------------------------------
# 4. Конфликтующие built-in .ko того же имени
# ---------------------------------------------------------------------------
BUILTIN_DIR="/lib/modules/$KVER/kernel/drivers/net/wireless/aic8800"
if [[ -f "$BUILTIN_DIR/aic8800_fdrv.ko" || -f "$BUILTIN_DIR/aic8800_fdrv.ko.xz" ]]; then
    warn "Обнаружены built-in модули в $BUILTIN_DIR — они могут"
    warn "конфликтовать с версией, которую соберёт DKMS (в updates/dkms/)."
    read -r -p "Удалить built-in версии перед сборкой DKMS? [y/N] " ans
    if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
        sudo mkdir -p /root/aic8800_builtin_backup
        sudo mv "$BUILTIN_DIR"/*.ko* /root/aic8800_builtin_backup/ 2>/dev/null || true
        log "Перемещены в /root/aic8800_builtin_backup/"
    fi
fi

# ---------------------------------------------------------------------------
# 5. Сборка и установка через DKMS
# ---------------------------------------------------------------------------
log "== dkms build -m $MOD_NAME -v $MOD_VER -k $KVER --force =="
if ! sudo dkms build -m "$MOD_NAME" -v "$MOD_VER" -k "$KVER" --force; then
    die "dkms build завершился ошибкой. Смотрите /var/lib/dkms/$MOD_NAME/$MOD_VER/build/make.log"
fi

log "== dkms install -m $MOD_NAME -v $MOD_VER -k $KVER --force =="
if ! sudo dkms install -m "$MOD_NAME" -v "$MOD_VER" -k "$KVER" --force; then
    die "dkms install завершился ошибкой."
fi

sudo depmod -a "$KVER"

# ---------------------------------------------------------------------------
# 6. Загрузка модуля и проверка
# ---------------------------------------------------------------------------
log "== Загрузка модуля =="
sudo modprobe -r aic8800_fdrv 2>/dev/null || true
sudo modprobe aic8800_fdrv
RC=$?
log "modprobe exit code: $RC"

if [[ $RC -ne 0 ]]; then
    err "Модуль не загрузился. Последние строки dmesg:"
    sudo dmesg | tail -15
    if sudo dmesg | tail -30 | grep -q "disagrees about version"; then
        err ""
        err "Это несовпадение CRC символов ядра (vermagic mismatch)."
        err "Модуль собран не против того дерева, что реально запущено."
        err "Убедитесь, что /lib/modules/$KVER/build указывает именно"
        err "на дерево исходников этого конкретного ядра (см. warning выше)."
    fi
    exit 1
fi

log "== lsmod =="
lsmod | grep aic8800

log "== USB-устройство =="
if lsusb | grep -qi "a69c:8d81"; then
    log "AIC8800D80 виден на USB-шине (OK)."
else
    warn "AIC8800D80 не виден в lsusb. Модуль загружен, но чип не"
    warn "отвечает физически — проверьте внутренний USB-разъём/шлейф,"
    warn "либо попробуйте полную перезагрузку платы (не просто"
    warn "переподключение модуля программно)."
fi

log "== Сетевые интерфейсы =="
ip link show

echo ""
echo "============================================================"
if ip link show | grep -q "wlan0"; then
    echo " wlan0 обнаружен — WiFi готов к использованию."
    echo " Подключение к сети, например через nmcli или wpa_supplicant."
else
    echo " wlan0 пока не появился. Если lsusb выше показал устройство,"
    echo " подождите несколько секунд и проверьте снова:"
    echo "   ip link show"
    echo " Если по-прежнему нет — перезагрузите плату и проверьте заново"
    echo " (после чистой перезагрузки часто проходит):"
    echo "   sudo reboot"
fi
echo "============================================================"
