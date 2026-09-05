#!/bin/bash
#
# deploy_ov9281.sh — сборка ЯДРА ROCK 4D с OV9281 (built-in камера).
#
# WiFi (AIC8800) больше НЕ собирается здесь — только на самой плате,
# отдельным скриптом install_wifi.sh (после reboot в новое ядро).
# Причина: собранные в WSL host-инструменты (fixdep/conf/modpost) — это
# x86_64-бинарники, которые не запустятся на ARM-плате. Компилировать их
# и сам WiFi-драйвер нужно НАТИВНО, на самой плате.
#
# Создаётся ОДИН архив ov9281-<версия>.tar.gz с двумя подпапками внутри:
#   boot/     — Image + modules + dtb + overlay + config-plain +
#               live_auto_exposure.cpp
#   headers/  — Makefile/.config/Module.symvers/include/arch/scripts/
#               Kconfig/tools — нужны на плате, чтобы собрать WiFi
#
# Команды:
#   ./deploy_ov9281.sh build <ИМЯ>    — собрать ядро + упаковать в ОДИН архив
#   ./deploy_ov9281.sh package        — упаковать отдельно (build уже делает это сама)
#   ./deploy_ov9281.sh deploy <IP>    — ТОЛЬКО отправить готовое на плату
#   ./deploy_ov9281.sh all <IP> <ИМЯ> — build, затем deploy, подряд
#   ./deploy_ov9281.sh clean          — полная очистка (.config сохраняется)
#
# На плате после deploy:
#   sudo ./install_kernel.sh   — ядро + overlay + распаковка headers (из boot/+headers/)
#   sudo reboot
#   sudo ./install_wifi.sh     — сборка scripts + WiFi-драйвера НАТИВНО, установка, проверка
#
set -e
set -o pipefail

ARCH=arm64
CROSS_COMPILE=aarch64-linux-gnu-
BOARD_USER=radxa
CUR_DIR=$(pwd)
LOG="deploy_ov9281.log"

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
    run rm -f .config .config.old .ov9281_kver deploy_ov9281.log
    ok "Ядро очищено (.config удалён — build сам возьмёт свежий из эталона)"

    log "Удаление архивов..."
    run rm -f ov9281-*.tar.gz

    log "Удаление временных файлов..."
    run rm -rf /tmp/modules_* /tmp/kernel_pkg_* /tmp/headers_*

    step "ОЧИСТКА ЗАВЕРШЕНА"
}

# ============================================
# BUILD — ТОЛЬКО ядро (Image+modules+dtbs). Никакого AIC8800/Kconfig-сбора
# здесь больше нет — WiFi собирается на плате отдельным install_wifi.sh.
# ============================================
cmd_build() {
    local suffix="$1"
    [[ -n "$suffix" ]] || die "Укажите имя версии: $0 build <ИМЯ>"

    step "СБОРКА ЯДРА (версия: $suffix)"

    check_tree
    sync_config_from_reference

    if ! command -v aarch64-linux-gnu-gcc &> /dev/null; then
        log "Установка кросс-компилятора..."
        run sudo apt update
        run sudo apt install -y crossbuild-essential-arm64 gcc-aarch64-linux-gnu
    fi

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

    step "ИТОГ СБОРКИ"
    ok "СБОРКА ЗАВЕРШЕНА! Версия: $kver"
    log "Дальше: упаковка в 2 архива (boot + headers)..."

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

    log "Установка модулей ядра..."
    local modpath="/tmp/modules_$kver"
    run rm -rf "$modpath"
    run mkdir -p "$modpath"
    run make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE INSTALL_MOD_PATH="$modpath" modules_install || die "Ошибка установки модулей"

    local staging="/tmp/ov9281_pkg_$kver"
    run rm -rf "$staging"
    run mkdir -p "$staging/boot/lib"
    run mkdir -p "$staging/headers"

    log "=== boot/ — ядро, модули, dtb, overlay, .cpp ==="
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
    run mkdir -p "$staging/headers/arch"
    run cp -a arch/arm64 "$staging/headers/arch/"

    # scripts/ копируется КАК ЕСТЬ (x86-бинарники из WSL) — плата
    # пересоберёт их сама, нативно, командой install_wifi.sh.
    run cp -a scripts "$staging/headers/"

    # scripts/sorttable.c включает <tools/be_byteshift.h> — без каталога
    # tools/include пересборка 'scripts' на плате упадёт с "No such file".
    run mkdir -p "$staging/headers/tools"
    run cp -a tools/include "$staging/headers/tools/"

    # ВСЕ Kconfig-файлы по дереву — scripts/kconfig/conf при ЛЮБОМ запуске
    # (даже просто syncconfig) обязан прочитать весь граф Kconfig целиком.
    log "Копирование ВСЕХ Kconfig-файлов по дереву..."
    run find . -name "Kconfig*" -exec cp --parents {} "$staging/headers/" \;

    echo "$kver" > "$staging/headers/kernel.release"

    log "=== Сборка единого архива ov9281-$kver.tar.gz ==="
    run tar czf "$CUR_DIR/ov9281-$kver.tar.gz" -C "$staging" . || die "Ошибка создания архива"
    ok "Архив создан: ov9281-$kver.tar.gz ($(du -h "$CUR_DIR/ov9281-$kver.tar.gz" | cut -f1))"

    log "=== Список файлов в архиве (первые 60 на экран, полный список — в $LOG) ==="
    tar tzvf "$CUR_DIR/ov9281-$kver.tar.gz" > /tmp/pkg_manifest_$kver.txt
    cat /tmp/pkg_manifest_$kver.txt >> "$LOG"
    head -60 /tmp/pkg_manifest_$kver.txt
    log "Всего файлов в архиве: $(wc -l < /tmp/pkg_manifest_$kver.txt) (полный список — в $LOG)"

    if grep -qi "^\./boot/.*ov9281" /tmp/pkg_manifest_$kver.txt; then
        warn "Внимание: в boot/ НАЙДЕНО что-то с именем ov9281 — это НЕ ожидалось (ov9281 должен быть built-in внутри Image, не отдельным файлом). Проверьте вручную:"
        grep -i "^\./boot/.*ov9281" /tmp/pkg_manifest_$kver.txt
    else
        log "В boot/ НЕТ отдельного ov9281.ko — это ОЖИДАЕМО: код built-in внутри самого Image (см. проверку символов выше в этом логе)."
    fi

    log "Удаление временных staging-папок..."
    run rm -rf "$modpath" "$staging"

    step "УПАКОВКА ЗАВЕРШЕНА"
}

# ============================================
# DEPLOY — ТОЛЬКО отправка единого архива + install-скриптов на плату.
# ============================================
cmd_deploy() {
    local ip="$1"
    [[ -n "$ip" ]] || die "Укажите IP: $0 deploy <IP>"

    [[ -f .ov9281_kver ]] || die "Сначала выполните: $0 build <ИМЯ>"
    local kver
    kver=$(cat .ov9281_kver)
    log "Версия: $kver"

    local pkg="$CUR_DIR/ov9281-$kver.tar.gz"
    [[ -f "$pkg" ]] || die "Не найден $pkg — сначала выполните: $0 build <ИМЯ>"

    step "ОТПРАВКА НА ПЛАТУ $ip"

    for script in install_kernel.sh install_wifi.sh; do
        [[ -f "$CUR_DIR/$script" ]] || die "Не найден $CUR_DIR/$script рядом со скриптом deploy_ov9281.sh — он должен лежать в этой же папке."
    done

    local files_to_copy=(
        "$pkg"
        "$CUR_DIR/install_kernel.sh"
        "$CUR_DIR/install_wifi.sh"
    )

    echo ""
    log "Отправляю на $BOARD_USER@$ip:"
    for f in "${files_to_copy[@]}"; do
        log "  - $(basename "$f") ($(du -h "$f" 2>/dev/null | cut -f1))"
    done
    echo ""

    run scp -o ConnectTimeout=10 "${files_to_copy[@]}" "$BOARD_USER@$ip":~/ || die "Не удалось скопировать файлы"

    echo ""
    echo "============================================================"
    echo " ОТПРАВЛЕНО. Дальше на плате:"
    echo ""
    echo "   ssh $BOARD_USER@$ip"
    echo "   chmod +x install_kernel.sh install_wifi.sh"
    echo "   sudo ./install_kernel.sh"
    echo "   sudo reboot"
    echo ""
    echo "   uname -r                    (ожидается: $kver)"
    echo "   sudo ./install_wifi.sh      (сборка scripts + WiFi-драйвера НАТИВНО)"
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
  DEPLOY_OV9281.SH — сборка ядра ROCK 4D (built-in OV9281)
============================================================

WiFi (AIC8800) собирается ОТДЕЛЬНО, НА ПЛАТЕ, скриптом install_wifi.sh
(после reboot в новое ядро) — не здесь. Причина: host-инструменты
(fixdep/conf/modpost), собранные в WSL — x86_64, на ARM не запустятся.

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
  $0 deploy <IP>    — ТОЛЬКО отправить готовое на плату (+install-скрипты)
  $0 all <IP> <ИМЯ> — build, затем deploy, подряд
  $0 clean          — полная очистка (.config удаляется, эталонный файл не трогается)

Пример:
  $0 all 192.168.1.92 wifi9281

Если эталонного конфига ещё нет:
  ssh radxa@<IP_платы> "zcat /proc/config.gz" > radxa4d.config

На плате после deploy:
  sudo ./install_kernel.sh   — ядро + overlay + распаковка headers (из одного архива, БЕЗ сборки)
  sudo reboot
  sudo ./install_wifi.sh     — сборка scripts + WiFi НАТИВНО, установка, проверка

Файлы:
  ov9281-<версия>.tar.gz  — ОДИН архив: boot/ (Image+modules+dtb+overlay+cpp)
                            + headers/ (для сборки WiFi на плате)

Лог: $LOG
============================================================
EOF
}

# ============================================
# MAIN
# ============================================
case "${1:-}" in
    clean)   STEP_TOTAL=2; cmd_clean ;;
    build)   STEP_TOTAL=9; shift; cmd_build "$@" ;;
    package) STEP_TOTAL=2; cmd_package ;;
    deploy)  STEP_TOTAL=1; shift; cmd_deploy "$@" ;;
    all)     STEP_TOTAL=11; shift; cmd_all "$@" ;;
    help|"") cmd_help ;;
    *)       echo "Неизвестная команда: $1"; cmd_help ;;
esac
