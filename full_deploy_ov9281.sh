#!/bin/bash
#
# full_deploy_ov9281.sh — сборка ЯДРА ROCK 4D с OV9281 (built-in камера)
# + КРОСС-сборка WiFi-драйвера AIC8800 (4.0) здесь же, в WSL.
#
# На плате НИЧЕГО не компилируется: в архиве уже лежат готовые
# aic*_usb.ko и прошивка. install_wifi.sh больше не нужен (запасной вариант).
#
# Создаётся ОДИН архив ov9281-<версия>.tar.gz:
#   boot/     — Image + modules (вкл. updates/aic8800/*.ko) + dtb + overlay +
#               config-plain + firmware/aic8800_fw/USB + aic8800.conf +
#               live_auto_exposure.cpp
#   headers/  — заголовки (на случай сборки других модулей на плате)
#
# Команды:
#   ./full_deploy_ov9281.sh build <ИМЯ>    — собрать ядро + WiFi + упаковать
#   ./full_deploy_ov9281.sh package        — упаковать отдельно (build уже делает это сама)
#   ./full_deploy_ov9281.sh wifi           — только WiFi против уже собранного ядра + перепаковать
#   ./full_deploy_ov9281.sh deploy <IP>    — ТОЛЬКО отправить готовое на плату
#   ./full_deploy_ov9281.sh all <IP> <ИМЯ> — build, затем deploy, подряд
#   ./full_deploy_ov9281.sh clean          — полная очистка (.config удаляется, .deb-кэш aic8800 остаётся)
#
# На плате после deploy:
#   sudo ./install_kernel.sh   — ядро + модули + WiFi + overlay + headers
#   sudo reboot
#
set -e
set -o pipefail
set -E   # ERR-ловушка срабатывает и внутри функций

SCRIPT_VERSION="2026-11-16 r5 (WiFi в архиве, проверка vermagic через objcopy)"

# Любой неожиданный выход по set -e — НЕ молча, а с местом падения.
trap 'rc=$?; echo "" >&2; echo "ОШИБКА: скрипт прерван (код $rc) в строке $LINENO: $BASH_COMMAND" >&2; echo "[$(date "+%H:%M:%S")] ОШИБКА: прерван (код $rc) строка $LINENO: $BASH_COMMAND" >> "${LOG:-full_deploy_ov9281.log}" 2>/dev/null; exit $rc' ERR

ARCH=arm64
CROSS_COMPILE=aarch64-linux-gnu-
BOARD_USER=radxa
CUR_DIR=$(pwd)
LOG="full_deploy_ov9281.log"
PKG_PREFIX="ov9281"   # имя архива: ov9281-<версия>.tar.gz

log()  { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }
err()  { echo "ОШИБКА: $*" >&2; echo "[$(date '+%H:%M:%S')] ОШИБКА: $*" >> "$LOG"; }
die()  { err "$*"; exit 1; }
ok()   { echo "[$(date '+%H:%M:%S')] ✅ $*" | tee -a "$LOG"; }
warn() { echo "[$(date '+%H:%M:%S')] ⚠️  $*" | tee -a "$LOG"; }
# Печатает реальную команду ПЕРЕД выполнением — ничего не скрыто.
run()  { echo "+ $*" | tee -a "$LOG"; "$@" 2>&1 | tee -a "$LOG"; return "${PIPESTATUS[0]}"; }

STEP_COUNT=0
STEP_TOTAL=0
step() {
    STEP_COUNT=$((STEP_COUNT + 1))
    echo ""
    echo "################################################################"
    if [[ "$STEP_TOTAL" -gt 0 ]]; then
        echo "###  [ШАГ $STEP_COUNT/$STEP_TOTAL]  $*"
    else
        echo "###  $*"
    fi
    echo "################################################################"
    echo ""
}

check_tree() {
    [[ -f Makefile ]] || die "Запустите из папки с ядром"
}

# Проверяет, что все host-инструменты сборки ядра РЕАЛЬНО ЗАПУСКАЮТСЯ
# (а не просто "где-то лежат" — в WSL в PATH бывают недоступные
# Windows-пути, и тогда make падает с "flex: Permission denied").
check_host_deps() {
    local missing=0 t
    for t in flex bison bc make gcc perl openssl aarch64-linux-gnu-gcc; do
        if ! "$t" --version &>/dev/null; then
            warn "$t не запускается: $(type -a "$t" 2>&1 | head -3 | tr '\n' ' ')"
            missing=1
        fi
    done
    [[ -f /usr/include/openssl/ssl.h ]]  || { warn "нет заголовков libssl-dev"; missing=1; }
    [[ -f /usr/include/libelf.h ]]       || { warn "нет заголовков libelf-dev"; missing=1; }

    if [[ "$missing" -eq 1 ]]; then
        log "Установка зависимостей сборки ядра..."
        run sudo apt update
        run sudo apt install -y flex bison bc make gcc perl openssl libssl-dev libelf-dev \
            libncurses-dev dwarves cpio kmod rsync crossbuild-essential-arm64 gcc-aarch64-linux-gnu
        hash -r
        for t in flex bison bc aarch64-linux-gnu-gcc; do
            "$t" --version &>/dev/null || die "$t по-прежнему не запускается. Проверьте: type -a $t ; echo \$PATH (недоступные /mnt/c/... пути можно убрать: в /etc/wsl.conf [interop] appendWindowsPath=false, затем 'wsl --shutdown')"
        done
    fi
    ok "Host-инструменты сборки на месте (flex, bison, bc, gcc, aarch64-linux-gnu-gcc)"
}

# Всегда перезаписывает .config эталонным файлом (radxa4d.config /
# radxa4d_config / rock4d.config — поддерживаются варианты именования).
# ГАРАНТИРУЕТ сборку с заведомо чистого конфига, а не с версией .config,
# которая могла "поплыть" за много прошлых olddefconfig/ручных правок
# (см. историю со случайно включившимися CONFIG_DRM_NOUVEAU/
# CONFIG_DRM_ETNAVIV/CONFIG_VIDEO_MAX96712).
sync_config_from_reference() {
    local ref=""
    for candidate in radxa4d.config radxa4d_config rock4d.config; do
        [[ -f "$candidate" ]] && ref="$candidate" && break
    done
    [[ -n "$ref" ]] || die "Не найден эталонный конфиг (radxa4d.config / radxa4d_config / rock4d.config) — снимите заново с платы: ssh $BOARD_USER@<IP> \"zcat /proc/config.gz\" > radxa4d.config"

    run cp "$ref" .config
    ok "Конфиг взят из эталона: $ref → .config"
}

# ============================================
# AIC8800 WiFi — КРОСС-сборка здесь, в WSL, против только что собранного
# дерева ядра. На плате потом НИЧЕГО не компилируется: install_kernel.sh
# просто кладёт готовые .ko + прошивку. (install_wifi.sh больше не нужен,
# остаётся как запасной вариант.)
# Исходники — из официального aic8800-usb-dkms .deb (уже с патчами Radxa).
# ============================================
AIC_VER="4.0+git20250410.b99ca8b6-3"
AIC_TAG="4.0%2Bgit20250410.b99ca8b6-3"
AIC_URL="https://github.com/radxa-pkg/aic8800/releases/download/${AIC_TAG}"
AIC_CACHE="$CUR_DIR/aic8800_cache"
AIC_OUT="$AIC_CACHE/out"

build_aic8800() {
    local kver="$1"
    step "1.5 КРОСС-СБОРКА WiFi AIC8800 ($AIC_VER)"

    run mkdir -p "$AIC_CACHE"
    local dkms_deb="$AIC_CACHE/aic8800-usb-dkms_${AIC_VER}_all.deb"
    local fw_deb="$AIC_CACHE/aic8800-firmware_${AIC_VER}_all.deb"
    if [[ ! -s "$dkms_deb" || ! -s "$fw_deb" ]]; then
        log "Скачивание пакетов aic8800 $AIC_VER (один раз, дальше из кэша)..."
        run wget -q -O "$dkms_deb" "${AIC_URL}/aic8800-usb-dkms_${AIC_VER}_all.deb" || { rm -f "$dkms_deb"; die "Не скачался aic8800-usb-dkms"; }
        run wget -q -O "$fw_deb"   "${AIC_URL}/aic8800-firmware_${AIC_VER}_all.deb" || { rm -f "$fw_deb"; die "Не скачался aic8800-firmware"; }
    else
        log "Пакеты aic8800 взяты из кэша $AIC_CACHE"
    fi

    run rm -rf "$AIC_CACHE/src" "$AIC_CACHE/fw" "$AIC_OUT"
    run dpkg-deb -x "$dkms_deb" "$AIC_CACHE/src"
    run dpkg-deb -x "$fw_deb"   "$AIC_CACHE/fw"
    local drv="$AIC_CACHE/src/usr/src/aic8800-usb-$AIC_VER/USB/driver_fw/drivers"
    [[ -d "$drv/aic8800" && -d "$drv/aic_btusb" ]] || die "Неожиданная структура пакета: нет $drv/aic8800 или aic_btusb"

    log "Сборка aic8800 (aic_load_fw + aic8800_fdrv)..."
    run make -j"$(nproc)" -C "$CUR_DIR" M="$drv/aic8800" ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE modules \
        || die "Ошибка кросс-сборки aic8800 (см. вывод выше)"
    log "Сборка aic_btusb (Bluetooth)..."
    run make -j"$(nproc)" -C "$CUR_DIR" M="$drv/aic_btusb" ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE modules \
        || die "Ошибка кросс-сборки aic_btusb (см. вывод выше)"

    # Имена как у DKMS-пакета (*_usb) — чтобы совпадали с modprobe и
    # /etc/modules-load.d/aic8800.conf, которые уже используются на плате.
    run mkdir -p "$AIC_OUT"
    run cp "$drv/aic8800/aic_load_fw/aic_load_fw.ko"     "$AIC_OUT/aic_load_fw_usb.ko"
    run cp "$drv/aic8800/aic8800_fdrv/aic8800_fdrv.ko"   "$AIC_OUT/aic8800_fdrv_usb.ko"
    run cp "$drv/aic_btusb/aic_btusb.ko"                 "$AIC_OUT/aic_btusb_usb.ko"
    run ${CROSS_COMPILE}strip --strip-debug "$AIC_OUT"/*.ko

    # Без пайпов с ранним выходом (grep -q / grep -m1): при pipefail они
    # дают SIGPIPE и set -e молча роняет скрипт.
    local ko vm finfo
    for ko in "$AIC_OUT"/*.ko; do
        finfo=$(file -b "$ko" 2>&1 || true)
        [[ "$finfo" == *"ARM aarch64"* ]] || die "$(basename "$ko") — не ARM64: $finfo"
        vm=$(${CROSS_COMPILE}objcopy -O binary --only-section=.modinfo "$ko" /dev/stdout 2>/dev/null \
             | tr '\0' '\n' | awk -F= '$1=="vermagic"{split($2,a," "); print a[1]; exit}' || true)
        [[ "$vm" == "$kver" ]] || die "$(basename "$ko"): vermagic '$vm' ≠ ядру '$kver'"
        ok "$(basename "$ko") — ARM64, vermagic $vm, $(du -h "$ko" | cut -f1)"
    done

    [[ -d "$AIC_CACHE/fw/lib/firmware/aic8800_fw/USB" ]] || die "В пакете прошивки нет aic8800_fw/USB"
    ok "WiFi AIC8800 собран — на плате компилировать ничего не нужно"
}

# ============================================
# CLEAN
# ============================================
cmd_clean() {
    step "ПОЛНАЯ ОЧИСТКА"

    # .config больше не нужно спасать/восстанавливать здесь — build сам
    # всегда берёт свежую копию из эталона (radxa4d.config/radxa4d_config/
    # rock4d.config) через sync_config_from_reference(). Сами эталонные
    # файлы (не .config) эта команда не трогает.
    log "Очистка ядра (make clean + mrproper)..."
    run make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE clean || true
    run make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE mrproper || true
    run rm -f .config .config.old .ov9281_kver full_deploy_ov9281.log
    ok "Ядро очищено (.config удалён — build сам возьмёт свежий из эталона)"

    log "Удаление архивов..."
    run rm -f ${PKG_PREFIX}-*.tar.gz

    log "Удаление временных файлов..."
    run rm -rf /tmp/modules_* /tmp/kernel_pkg_* /tmp/headers_* /tmp/ov9281_pkg_*
    run rm -rf "$AIC_CACHE/src" "$AIC_CACHE/fw" "$AIC_OUT"   # .deb в кэше оставляем

    step "ОЧИСТКА ЗАВЕРШЕНА"
}

# ============================================
# BUILD — ядро (Image+modules+dtbs) + кросс-сборка WiFi AIC8800.
# ============================================
cmd_build() {
    local suffix="$1"
    [[ -n "$suffix" ]] || die "Укажите имя версии: $0 build <ИМЯ>"

    step "СБОРКА ЯДРА (версия: $suffix)"

    check_tree
    sync_config_from_reference

    check_host_deps

    step "1.1 НАСТРОЙКА .config"

    log "Настройка версии: -$suffix"
    run ./scripts/config --file .config --disable CONFIG_LOCALVERSION_AUTO || true
    run ./scripts/config --file .config --set-str CONFIG_LOCALVERSION "-$suffix" || true
    run ./scripts/config --file .config --enable CONFIG_VIDEO_OV9281 || true
    run ./scripts/config --file .config --enable CONFIG_ARCH_ROCKCHIP || true
    run ./scripts/config --file .config --disable CONFIG_KASAN || true
    run ./scripts/config --file .config --enable CONFIG_CFG80211 || true
    run ./scripts/config --file .config --enable CONFIG_MAC80211 || true
    run ./scripts/config --file .config --enable CONFIG_USB || true

    log "Обновление конфига (olddefconfig)..."
    run make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE olddefconfig

    step "1.2 ПРОВЕРКА .config И ПАТЧА OV9281"

    local config_ok=1

    if grep -q "^CONFIG_VIDEO_OV9281=y" .config; then
        ok "OV9281: ВКЛЮЧЕН built-in (CONFIG_VIDEO_OV9281=y)"
    elif grep -q "^CONFIG_VIDEO_OV9281=m" .config; then
        warn "OV9281: как модуль (CONFIG_VIDEO_OV9281=m) — обычно нужен built-in (=y) из-за таймингов rkcif/rkisp"
    else
        err "OV9281: НЕ НАЙДЕН в .config"
        config_ok=0
    fi

    if grep -q "^CONFIG_ARCH_ROCKCHIP=y" .config; then
        ok "ROCKCHIP: ВКЛЮЧЕН"
    else
        err "ROCKCHIP: НЕ НАЙДЕН — без него не соберутся .dtb для платы"
        config_ok=0
    fi

    if grep -q "^CONFIG_KASAN=y" .config; then
        err "KASAN: ВКЛЮЧЕН — ломает сборку сторонних модулей (WiFi на плате)"
        config_ok=0
    else
        ok "KASAN: ВЫКЛЮЧЕН"
    fi

    if grep -q "^CONFIG_CFG80211=y\|^CONFIG_CFG80211=m" .config; then
        ok "CFG80211: включён ($(grep '^CONFIG_CFG80211=' .config))"
    else
        err "CFG80211: НЕ включён — WiFi-подсистема ядра отсутствует"
        config_ok=0
    fi

    if grep -q "^CONFIG_MAC80211=y\|^CONFIG_MAC80211=m" .config; then
        ok "MAC80211: включён ($(grep '^CONFIG_MAC80211=' .config))"
    else
        err "MAC80211: НЕ включён"
        config_ok=0
    fi

    if grep -q "^CONFIG_USB=y\|^CONFIG_USB=m" .config; then
        ok "USB: включён ($(grep '^CONFIG_USB=' .config))"
    else
        err "USB: НЕ включён — AIC8800 подключается по USB, без этого работать не будет"
        config_ok=0
    fi

    [[ "$config_ok" -eq 1 ]] || die "Проверка .config провалена (см. ошибки выше) — сборка остановлена."

    if grep -q "GPIOD_OUT_LOW" drivers/media/i2c/ov9281.c 2>/dev/null; then
        ok "Патч GPIOD_OUT_LOW в ov9281.c — на месте (иначе камера даст 'Unexpected sensor id')"
    else
        err "Патч GPIOD_OUT_LOW НЕ найден в drivers/media/i2c/ov9281.c!"
        die "Камера не заработает без этого патча (GPIOD_ASIS -> GPIOD_OUT_LOW). Примените патч перед сборкой."
    fi

    local overlay_src
    overlay_src=$(find . -maxdepth 2 -iname "*ov9281*.dts" | head -1)
    if [[ -n "$overlay_src" ]]; then
        if grep -q "0x1e 0x00" "$overlay_src"; then
            ok "Overlay найден ($overlay_src), полярность pwdn-gpios = 0x00 (верная)"
        else
            warn "Overlay найден, но полярность pwdn-gpios не 0x00 — проверьте вручную (нужна GPIO_ACTIVE_HIGH)"
        fi
    else
        die "Overlay .dts не найден (ожидается ./overlay/*.dts) — камера не заработает."
    fi

    # --- НОВОЕ: точечная компиляция ТОЛЬКО drivers/media/i2c/ov9281.o ---
    # Даёт быструю обратную связь по ошибкам именно в этом (патченном)
    # файле, не дожидаясь полной сборки Image+modules+dtbs (которая
    # занимает намного больше времени). Если файл не компилируется —
    # нет смысла запускать долгую полную сборку вообще.
    step "1.3 ТОЧЕЧНАЯ КОМПИЛЯЦИЯ drivers/media/i2c/ov9281.c"

    log "Удаление старого .o (если есть) — иначе make может решить, что пересборка не нужна..."
    run rm -f drivers/media/i2c/ov9281.o drivers/media/i2c/.ov9281.o.cmd

    log "Компиляция ТОЛЬКО ov9281.o..."
    if run make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE drivers/media/i2c/ov9281.o; then
        if [[ -f drivers/media/i2c/ov9281.o ]]; then
            ok "drivers/media/i2c/ov9281.o собран успешно ($(ls -la drivers/media/i2c/ov9281.o | awk '{print $5}') байт)"
        else
            die "make завершился без ошибки, но ov9281.o не создан — странная ситуация, проверьте вручную."
        fi
    else
        die "Ошибка компиляции drivers/media/i2c/ov9281.c — смотрите вывод выше. Полная сборка ядра остановлена, чтобы не тратить время впустую."
    fi

    step "1.4 СБОРКА Image + modules + dtbs"

    log "Сборка (параллельно: $(nproc) потоков)..."
    run make -j$(nproc) ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE Image modules dtbs || die "Ошибка сборки ядра"

    [[ -f "arch/arm64/boot/Image" ]] || die "Ошибка сборки ядра: Image не создан!"

    local kver
    kver=$(cat include/config/kernel.release 2>/dev/null || echo "unknown")
    echo "$kver" > .ov9281_kver
    ok "ЯДРО СОБРАНО! Версия: $kver"
    log "Image: $(ls -la arch/arm64/boot/Image | awk '{print $5, $9}')"

    # --- ДОКАЗАТЕЛЬСТВО, что ov9281.c реально скомпилирован и попал
    # ВНУТРЬ Image (built-in, а не отдельный .ko — .ko у built-in кода
    # просто не существует в принципе, это не ошибка, а прямое следствие
    # того, что CONFIG_VIDEO_OV9281=y). Проверяем по символам в vmlinux
    # (ELF с полной отладочной информацией) или, если vmlinux не сохранён,
    # по System.map (список всех символов ядра с адресами).
    step "ПРОВЕРКА: ov9281 РЕАЛЬНО СКОМПИЛИРОВАН И ВКОМПИЛИРОВАН В IMAGE"
    log "ov9281 — built-in (CONFIG_VIDEO_OV9281=y), поэтому .ko НЕ существует"
    log "в принципе — код становится частью самого Image, а не отдельным"
    log "файлом модуля. Проверяем по символам ядра, что компиляция и"
    log "линковка реально прошли успешно:"

    local ov9281_symbols=""
    if [[ -f vmlinux ]]; then
        ov9281_symbols=$(nm vmlinux 2>/dev/null | grep -i ov9281 || true)
    fi
    if [[ -z "$ov9281_symbols" && -f System.map ]]; then
        ov9281_symbols=$(grep -i ov9281 System.map || true)
    fi

    if [[ -n "$ov9281_symbols" ]]; then
        ok "Символы ov9281 найдены в собранном ядре (доказательство успешной компиляции+линковки):"
        echo "$ov9281_symbols" | head -15 | tee -a "$LOG"
        local symcount
        symcount=$(echo "$ov9281_symbols" | wc -l)
        log "Всего найдено символов: $symcount"
    else
        die "Символы ov9281 НЕ найдены ни в vmlinux, ни в System.map — компиляция могла пройти, но код не попал в финальный Image! Проверьте вручную."
    fi

    build_aic8800 "$kver"

    step "ИТОГ СБОРКИ"
    ok "СБОРКА ЗАВЕРШЕНА! Версия: $kver"
    log "Дальше: упаковка в ОДИН архив (boot/ + headers/)..."

    cmd_package
}

# ============================================
# PACKAGE — ОДИН архив (boot/ + headers/ подпапки внутри). Никакой сборки
# AIC8800/scripts здесь нет — scripts копируются КАК ЕСТЬ (x86-бинарники),
# плата пересоберёт их сама.
# ============================================
cmd_package() {
    local kver
    kver=$(cat .ov9281_kver 2>/dev/null) || die "Сначала выполните build"
    [[ -f arch/arm64/boot/Image ]] || die "Нет Image"

    step "УПАКОВКА В ОДИН АРХИВ (boot/ + headers/)"

    command -v rsync &>/dev/null || { run sudo apt install -y rsync; }

    # Остатки прошлых (в т.ч. упавших) упаковок
    rm -rf /tmp/modules_* /tmp/ov9281_pkg_* /tmp/pkg_manifest_* 2>/dev/null || true

    # Нужно места: модули (~1 ГБ с отладкой) + headers + архив. Требуем 4 ГБ
    # свободных и в /tmp, и в папке с ядром — иначе WSL уйдёт в read-only.
    local d free_kb
    for d in /tmp "$CUR_DIR"; do
        free_kb=$(df -Pk "$d" | awk 'NR==2{print $4}')
        if [[ "$free_kb" -lt $((4*1024*1024)) ]]; then
            df -h "$d"
            die "В $d свободно меньше 4 ГБ ($((free_kb/1024)) МБ) — освободите место перед упаковкой"
        fi
    done
    log "Свободно: /tmp — $(df -h /tmp | awk 'NR==2{print $4}'), $CUR_DIR — $(df -h "$CUR_DIR" | awk 'NR==2{print $4}')"

    log "Установка модулей ядра..."
    local modpath="/tmp/modules_$kver"
    run rm -rf "$modpath"
    run mkdir -p "$modpath"
    run make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE INSTALL_MOD_PATH="$modpath" INSTALL_MOD_STRIP=1 modules_install || die "Ошибка установки модулей"

    local staging="/tmp/ov9281_pkg_$kver"
    run rm -rf "$staging"
    run mkdir -p "$staging/boot/lib"
    run mkdir -p "$staging/headers"

    log "=== boot/ — ядро, модули, dtb, overlay, .cpp ==="
    # WiFi AIC8800: готовые .ko → updates/aic8800 внутри модулей ядра,
    # прошивка → boot/firmware, автозагрузка → boot/aic8800.conf
    if ls "$AIC_OUT"/*.ko &>/dev/null; then
        run mkdir -p "$modpath/lib/modules/$kver/updates/aic8800"
        run cp "$AIC_OUT"/*.ko "$modpath/lib/modules/$kver/updates/aic8800/"
        run mkdir -p "$staging/boot/firmware/aic8800_fw"
        run cp -a "$AIC_CACHE/fw/lib/firmware/aic8800_fw/USB" "$staging/boot/firmware/aic8800_fw/"
        printf "aic_load_fw_usb\naic8800_fdrv_usb\naic_btusb_usb\n" > "$staging/boot/aic8800.conf"
        ok "WiFi AIC8800 добавлен в архив (модули + прошивка USB)"
    else
        die "Нет собранных модулей WiFi в $AIC_OUT — выполните build (он соберёт их)"
    fi

    run cp -r "$modpath/lib/modules" "$staging/boot/lib/"
    run cp arch/arm64/boot/Image "$staging/boot/"
    cp arch/arm64/boot/dts/rockchip/rk3576-rock-4d.dtb "$staging/boot/" 2>/dev/null || true
    cp arch/arm64/boot/dts/rockchip/rk3576-rock-4d-spi.dtb "$staging/boot/" 2>/dev/null || true
    run cp .config "$staging/boot/config-plain"

    local overlay
    overlay=$(find . -maxdepth 2 -iname "*ov9281*.dts" | head -1)
    [[ -n "$overlay" ]] || die "Overlay .dts не найден — проверьте ./overlay/*.dts"
    run cp "$overlay" "$staging/boot/overlay.dts"
    ok "Overlay OV9281 добавлен: $overlay"

    if [[ -f "$CUR_DIR/live_auto_exposure.cpp" ]]; then
        run cp "$CUR_DIR/live_auto_exposure.cpp" "$staging/boot/"
        ok "live_auto_exposure.cpp добавлен"
    else
        warn "live_auto_exposure.cpp не найден рядом со скриптом — не будет включён в архив."
    fi

    log "=== headers/ — заголовки для сборки WiFi на плате ==="
    run cp -a Makefile .config Module.symvers "$staging/headers/"
    run cp -a include "$staging/headers/"
    # arch/arm64 — БЕЗ результатов сборки (.o/.a/.cmd/.ko/.dtb/Image и всего
    # boot/). Иначе копируются гигабайты, диск WSL переполняется и
    # переходит в read-only. Для сборки внешних модулей нужны только
    # Makefile, include/ (в т.ч. include/generated) и исходники Kconfig/tools.
    run mkdir -p "$staging/headers/arch"
    run rsync -a \
        --exclude='/arm64/boot/' \
        --exclude='*.o' --exclude='*.a' --exclude='.*.cmd' --exclude='*.ko' \
        --exclude='*.dtb' --exclude='*.dtbo' --exclude='*.mod' --exclude='*.mod.c' \
        --exclude='*.lds' --exclude='modules.order' --exclude='*.so' --exclude='*.dbg' \
        arch/arm64 "$staging/headers/arch/"
    log "headers/arch/arm64: $(du -sh "$staging/headers/arch/arm64" | cut -f1)"

    # scripts/ — исходники + x86-бинарники (плата пересоберёт их нативно
    # в install_wifi.sh). Объектные файлы не нужны.
    run rsync -a --exclude='*.o' --exclude='.*.cmd' scripts "$staging/headers/"

    # scripts/sorttable.c включает <tools/be_byteshift.h> — без каталога
    # tools/include пересборка 'scripts' на плате упадёт с "No such file".
    run mkdir -p "$staging/headers/tools"
    run cp -a tools/include "$staging/headers/tools/"

    # ВСЕ Kconfig-файлы по дереву — scripts/kconfig/conf при ЛЮБОМ запуске
    # (даже просто syncconfig) обязан прочитать весь граф Kconfig целиком.
    log "Копирование ВСЕХ Kconfig-файлов по дереву..."
    run find . -name "Kconfig*" -exec cp --parents {} "$staging/headers/" \;

    echo "$kver" > "$staging/headers/kernel.release"

    log "=== Сборка единого архива ${PKG_PREFIX}-$kver.tar.gz ==="
    run tar czf "$CUR_DIR/${PKG_PREFIX}-$kver.tar.gz" -C "$staging" . || die "Ошибка создания архива"
    ok "Архив создан: ${PKG_PREFIX}-$kver.tar.gz ($(du -h "$CUR_DIR/${PKG_PREFIX}-$kver.tar.gz" | cut -f1))"

    log "=== Список файлов в архиве (первые 60 на экран, полный список — в $LOG) ==="
    tar tzvf "$CUR_DIR/${PKG_PREFIX}-$kver.tar.gz" > /tmp/pkg_manifest_$kver.txt
    cat /tmp/pkg_manifest_$kver.txt >> "$LOG"
    head -60 /tmp/pkg_manifest_$kver.txt
    log "Всего файлов в архиве: $(wc -l < /tmp/pkg_manifest_$kver.txt) (полный список — в $LOG)"

    # Самопроверка архива: именно это проверяет install_kernel.sh на плате.
    tar tzf "$CUR_DIR/${PKG_PREFIX}-$kver.tar.gz" > /tmp/pkg_names_$kver.txt
    local need
    for need in "./boot/Image" "./boot/config-plain" "./boot/overlay.dts" \
                "./boot/lib/modules/$kver/modules.dep" \
                "./boot/lib/modules/$kver/updates/aic8800/aic8800_fdrv_usb.ko" \
                "./boot/lib/modules/$kver/updates/aic8800/aic_load_fw_usb.ko" \
                "./boot/firmware/aic8800_fw/USB" "./boot/aic8800.conf" \
                "./headers/kernel.release" "./headers/Module.symvers" "./headers/.config"; do
        grep -qxF -e "$need" -e "$need/" /tmp/pkg_names_$kver.txt || die "В архиве НЕТ $need — архив неполный, на плату не отправлять!"
    done
    [[ -s Module.symvers ]] || die "Module.symvers пустой — WiFi-модуль на плате не загрузится"
    rm -f /tmp/pkg_names_$kver.txt
    ok "Архив проверен: boot/Image, modules/$kver, overlay, headers/ — на месте"

    if grep -qi "^\./boot/.*ov9281" /tmp/pkg_manifest_$kver.txt; then
        warn "Внимание: в boot/ НАЙДЕНО что-то с именем ov9281 — это НЕ ожидалось (ov9281 должен быть built-in внутри Image, не отдельным файлом). Проверьте вручную:"
        grep -i "^\./boot/.*ov9281" /tmp/pkg_manifest_$kver.txt
    else
        log "В boot/ НЕТ отдельного ov9281.ko — это ОЖИДАЕМО: код built-in внутри самого Image (см. проверку символов выше в этом логе)."
    fi

    log "Удаление временных staging-папок..."
    run rm -rf "$modpath" "$staging"

    step "УПАКОВКА ЗАВЕРШЕНА"

    # IP платы: последний использованный в deploy (если был), иначе <IP>
    local ip_hint="<IP>"
    [[ -f "$CUR_DIR/.ov9281_last_ip" ]] && ip_hint=$(cat "$CUR_DIR/.ov9281_last_ip")

    echo "============================================================"
    echo " АРХИВ ГОТОВ: ${PKG_PREFIX}-$kver.tar.gz ($(du -h "$CUR_DIR/${PKG_PREFIX}-$kver.tar.gz" | cut -f1))"
    echo ""
    echo " ОТПРАВКА НА ПЛАТУ (одна из двух команд):"
    echo ""
    echo "   ./full_deploy_ov9281.sh deploy $ip_hint"
    echo ""
    echo "   или вручную:"
    echo "   scp \"${PKG_PREFIX}-$kver.tar.gz\" install_kernel.sh $BOARD_USER@$ip_hint:~/"
    echo ""
    echo " НА ПЛАТЕ:"
    echo "   ssh $BOARD_USER@$ip_hint"
    echo "   chmod +x install_kernel.sh"
    echo "   sudo ./install_kernel.sh"
    echo "   sudo reboot"
    echo "   uname -r                 (ожидается: $kver)"
    echo "   ip -br link              (WiFi-интерфейс wl* — драйвер уже в ядре, install_wifi.sh НЕ нужен)"
    echo "   nmcli device wifi list"
    echo "============================================================"
}

# ============================================
# DEPLOY — ТОЛЬКО отправка единого архива + install-скриптов на плату.
# ============================================
cmd_deploy() {
    local ip="$1"
    [[ -n "$ip" ]] || die "Укажите IP: $0 deploy <IP>"
    # Защита от путаницы "deploy <ИМЯ_ВЕРСИИ>" вместо "deploy <IP>"
    if ! [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && ! getent hosts "$ip" &>/dev/null; then
        die "'$ip' — не IP и не известное имя хоста. deploy только ОТПРАВЛЯЕТ на плату.
   Собрать всё (ядро + WiFi) в архив:  $0 build $ip
   Отправить на плату:                 $0 deploy <IP_платы>
   Собрать и сразу отправить:          $0 all <IP_платы> $ip"
    fi

    [[ -f .ov9281_kver ]] || die "Сначала выполните: $0 build <ИМЯ>"
    local kver
    kver=$(cat .ov9281_kver)
    log "Версия: $kver"
    echo "$ip" > "$CUR_DIR/.ov9281_last_ip"

    local pkg="$CUR_DIR/${PKG_PREFIX}-$kver.tar.gz"
    [[ -f "$pkg" ]] || die "Не найден $pkg — сначала выполните: $0 build <ИМЯ>"

    step "ОТПРАВКА НА ПЛАТУ $ip"

    [[ -f "$CUR_DIR/install_kernel.sh" ]] || die "Не найден $CUR_DIR/install_kernel.sh рядом со скриптом full_deploy_ov9281.sh — он должен лежать в этой же папке."

    local files_to_copy=(
        "$pkg"
        "$CUR_DIR/install_kernel.sh"
    )
    # install_wifi.sh больше не обязателен (WiFi собирается здесь) — запасной вариант
    [[ -f "$CUR_DIR/install_wifi.sh" ]] && files_to_copy+=("$CUR_DIR/install_wifi.sh")

    echo ""
    log "Отправляю на $BOARD_USER@$ip:"
    for f in "${files_to_copy[@]}"; do
        log "  - $(basename "$f") ($(du -h "$f" 2>/dev/null | cut -f1))"
    done
    echo ""

    # Старые архивы на плате ломают install_kernel.sh (мог взять не тот) —
    # переносим их в ~/ov9281_old/ (не удаляем).
    log "Перенос старых ov9281-*.tar.gz на плате в ~/ov9281_old/ ..."
    run ssh -o ConnectTimeout=10 "$BOARD_USER@$ip" \
        'mkdir -p ~/ov9281_old; for f in ~/ov9281-*.tar.gz; do [ -e "$f" ] && mv -v "$f" ~/ov9281_old/; done; true' \
        || warn "Не удалось почистить старые архивы на плате — проверьте ~ вручную"

    run scp -o ConnectTimeout=10 "${files_to_copy[@]}" "$BOARD_USER@$ip":~/ || die "Не удалось скопировать файлы"

    log "Проверка размера архива на плате..."
    local remote_size local_size
    local_size=$(stat -c %s "$pkg")
    remote_size=$(ssh -o ConnectTimeout=10 "$BOARD_USER@$ip" "stat -c %s ~/$(basename "$pkg")" 2>/dev/null || echo 0)
    [[ "$local_size" == "$remote_size" ]] || die "Размер архива на плате ($remote_size) ≠ локальному ($local_size) — передача оборвалась"
    ok "Архив на плате целый ($local_size байт)"

    echo ""
    echo "============================================================"
    echo " ОТПРАВЛЕНО. Дальше на плате:"
    echo ""
    echo "   ssh $BOARD_USER@$ip"
    echo "   chmod +x install_kernel.sh"
    echo "   sudo ./install_kernel.sh"
    echo "   sudo reboot"
    echo ""
    echo "   uname -r                    (ожидается: $kver)"
    echo "   ip -br link ; nmcli device wifi list   (WiFi уже в архиве — install_wifi.sh НЕ нужен)"
    echo "============================================================"
}

# ============================================
# ALL
# ============================================
cmd_all() {
    local ip="$1"
    local name="$2"
    [[ -n "$ip" && -n "$name" ]] || die "Использование: $0 all <IP> <ИМЯ>"

    step "ПОЛНЫЙ ЦИКЛ: build → deploy"
    cmd_build "$name"
    cmd_deploy "$ip"
}

# ============================================
# HELP
# ============================================
cmd_help() {
    cat << EOF
============================================================
  FULL_DEPLOY_OV9281.SH — сборка ядра ROCK 4D (built-in OV9281)
============================================================

WiFi (AIC8800 $AIC_VER) КРОСС-собирается здесь же, вместе с ядром,
и кладётся в архив готовыми .ko + прошивка. На плате ничего не компилируется.

.config ВСЕГДА берётся заново из эталонного файла перед сборкой (первый
найденный: radxa4d.config / radxa4d_config / rock4d.config) — никогда не
переиспользуется предыдущий .config, чтобы избежать "поплывшего" за много
правок конфига (были случаи случайно включавшихся CONFIG_DRM_NOUVEAU и
подобных нерелевантных драйверов, ломавших сборку).

build теперь ДОПОЛНИТЕЛЬНО точечно компилирует ТОЛЬКО
drivers/media/i2c/ov9281.o перед полной сборкой Image+modules+dtbs —
если в этом (патченном) файле есть ошибка, вы узнаете об этом за
секунды, а не после долгой полной сборки.

Команды:
  $0 build <ИМЯ>    — взять эталонный конфиг, собрать ядро, упаковать в ОДИН архив
  $0 package        — упаковать отдельно (build уже делает это сама)
  $0 wifi           — ТОЛЬКО собрать WiFi против уже собранного ядра + перепаковать
  $0 deploy <IP>    — ТОЛЬКО отправить готовое на плату (+install-скрипты)
  $0 all <IP> <ИМЯ> — build, затем deploy, подряд
  $0 clean          — полная очистка (.config удаляется, эталонный файл не трогается)

Пример:
  $0 all 192.168.1.92 wifi9281

Если эталонного конфига ещё нет:
  ssh radxa@<IP_платы> "zcat /proc/config.gz" > radxa4d.config

На плате после deploy:
  sudo ./install_kernel.sh   — ядро + модули + WiFi + overlay + headers (БЕЗ компиляции)
  sudo reboot
  ip -br link ; nmcli device wifi list

Файлы:
  ov9281-<версия>.tar.gz  — ОДИН архив: boot/ (Image+modules+WiFi+dtb+overlay+cpp)
                            + headers/

Лог: $LOG
============================================================
EOF
}

# ============================================
# MAIN
# ============================================
echo "$(basename "$0") — версия скрипта: $SCRIPT_VERSION"
case "${1:-}" in
    clean)   STEP_TOTAL=2; cmd_clean ;;
    build)   STEP_TOTAL=10; shift; cmd_build "$@" ;;
    package) STEP_TOTAL=2; cmd_package ;;
    wifi)    STEP_TOTAL=3; check_tree
             [[ -f .ov9281_kver && -f arch/arm64/boot/Image ]] || die "Ядро ещё не собрано — сначала: $0 build <ИМЯ>"
             build_aic8800 "$(cat .ov9281_kver)"; cmd_package ;;
    deploy)  STEP_TOTAL=1; shift; cmd_deploy "$@" ;;
    all)     STEP_TOTAL=12; shift; cmd_all "$@" ;;
    help|"") cmd_help ;;
    *)       echo "Неизвестная команда: $1"; cmd_help ;;
esac
