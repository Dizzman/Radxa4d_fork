#!/bin/bash
#
# build_wsl_ov9281.sh
#
# Сборка ядра ROCK 4D в WSL с built-in камерой OV9281, для форка
# Radxa/kernel с уже подключённым submodule aic8800 (WiFi) и overlay.
#
# Учтены все проблемы, найденные экспериментально в этой сессии:
#   - CONFIG_KASAN может незаметно включиться при olddefconfig —
#     проверяется и принудительно отключается.
#   - НИКОГДА не делает 'make clean' — это удаляет scripts/module.lds
#     (нужен для сборки внешних модулей типа WiFi на arm64 с PLT).
#   - Переносит НА ПЛАТУ полное дерево сборки (не только Image+modules),
#     чтобы /usr/src/linux-headers-<ver> был настоящим, а не фиктивной
#     копией другого ядра, которую иначе может подставить DKMS сам.
#
# Использование (внутри уже склонированного и настроенного репозитория,
# на нужной ветке, с патчем камеры и .config уже закоммиченными):
#
#   ./build_wsl_ov9281.sh check      # проверить состояние перед сборкой
#   ./build_wsl_ov9281.sh build      # собрать Image+modules+dtbs
#   ./build_wsl_ov9281.sh package    # упаковать для переноса на плату
#
set -uo pipefail

ARCH=arm64
CROSS_COMPILE=aarch64-linux-gnu-
LOGFILE="build_wsl_ov9281.log"

log()  { echo -e "[$(date '+%H:%M:%S')] $*" | tee -a "$LOGFILE"; }
err()  { echo -e "[$(date '+%H:%M:%S')] ОШИБКА: $*" | tee -a "$LOGFILE" >&2; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# check: убедиться, что дерево готово к сборке
# ---------------------------------------------------------------------------
cmd_check() {
    log "== Проверка перед сборкой =="

    [[ -f Makefile ]] || die "Не похоже на корень дерева ядра (нет Makefile). Запустите скрипт из папки с исходниками."

    local ver pl sl
    ver=$(grep -m1 '^VERSION' Makefile | awk '{print $3}')
    pl=$(grep -m1 '^PATCHLEVEL' Makefile | awk '{print $3}')
    sl=$(grep -m1 '^SUBLEVEL' Makefile | awk '{print $3}')
    log "Версия дерева: $ver.$pl.$sl"
    if [[ "$ver.$pl" != "6.1" ]]; then
        die "Ожидалось ядро 6.1.x (для платы ROCK 4D с 6.1.84-12-rk2410-nocsf), найдено $ver.$pl.$sl. Проверьте, на той ли ветке вы находитесь (git branch)."
    fi

    [[ -f .config ]] || die "Нет .config в корне дерева. Сначала: ssh radxa@<IP> \"zcat /proc/config.gz\" > .config"

    if grep -q "^CONFIG_KASAN=y" .config; then
        die "CONFIG_KASAN=y в .config — это ломает сборку внешних модулей (WiFi). Отключите: ./scripts/config --file .config --disable CONFIG_KASAN && make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE olddefconfig"
    fi
    log "CONFIG_KASAN — не установлен (OK)."

    if ! grep -q "^CONFIG_VIDEO_OV9281=y" .config; then
        die "CONFIG_VIDEO_OV9281 не =y в .config. Установите: ./scripts/config --file .config --enable CONFIG_VIDEO_OV9281 && make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE olddefconfig"
    fi
    log "CONFIG_VIDEO_OV9281=y (OK)."

    if grep -q "GPIOD_OUT_LOW" drivers/media/i2c/ov9281.c 2>/dev/null; then
        log "Патч GPIOD_OUT_LOW в ov9281.c — на месте (OK)."
    else
        err "Патч GPIOD_OUT_LOW НЕ найден в drivers/media/i2c/ov9281.c! Камера не будет работать (Unexpected sensor id)."
    fi

    if [[ -f overlay/rock4d-ov9281.dts ]] || find . -maxdepth 2 -iname "*ov9281*.dts" | grep -q .; then
        log "Overlay-файл камеры найден (OK)."
    else
        err "Overlay-файл камеры не найден — потребуется передать его на плату отдельно."
    fi

    if [[ -d aic8800/src ]]; then
        log "Каталог aic8800/src присутствует (WiFi driver source) — будет собираться отдельно через DKMS на плате (см. вывод package)."
    else
        log "Предупреждение: aic8800/src не найден — если нужен WiFi, submodule не инициализирован (git submodule update --init, либо .gitmodules отсутствует)."
    fi

    log "Проверка завершена. Можно запускать: $0 build"
}

# ---------------------------------------------------------------------------
# build: сборка Image+modules+dtbs
# ---------------------------------------------------------------------------
cmd_build() {
    cmd_check || die "Проверка не пройдена, сборка не запущена."

    log "== Синхронизация .config (yes '' | olddefconfig) перед сборкой =="
    log "Это предотвращает уход в интерактивные вопросы посреди make Image."
    yes '' | make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig 2>&1 | tee -a "$LOGFILE"

    # olddefconfig может незаметно включить то, что мы явно выключали —
    # перепроверяем сразу после синхронизации, до долгой сборки.
    if grep -q "^CONFIG_KASAN=y" .config; then
        log "olddefconfig снова включил CONFIG_KASAN — отключаю повторно."
        ./scripts/config --file .config --disable CONFIG_KASAN
        make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig 2>&1 | tee -a "$LOGFILE"
    fi
    grep -q "^CONFIG_VIDEO_OV9281=y" .config || die "CONFIG_VIDEO_OV9281 потерялся после olddefconfig — проверьте .config вручную."
    grep -q "^CONFIG_KASAN=y" .config && die "CONFIG_KASAN всё ещё =y после повторного отключения — остановлено, чтобы не повторить прошлую проблему с WiFi."
    log "Конфиг синхронизирован и проверен (OK)."

    log "== Сборка Image+modules+dtbs (ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE) =="
    log "НАПОМИНАНИЕ: после этой сборки НЕ выполняйте 'make clean' в этом дереве —"
    log "это удалит scripts/module.lds, нужный для сборки WiFi-модуля на плате."

    make -j"$(nproc)" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" Image modules dtbs 2>&1 | tee -a "$LOGFILE"

    [[ -f arch/arm64/boot/Image ]] || die "arch/arm64/boot/Image не создан — сборка не удалась, смотрите $LOGFILE."

    local kver
    kver=$(cat include/config/kernel.release)
    log "Сборка завершена. Версия: $kver"

    if [[ -f scripts/module.lds ]] && grep -q '\.plt' scripts/module.lds; then
        log "scripts/module.lds содержит секции .plt — сборка внешних модулей (WiFi) на плате должна пройти без проблем с PLT."
    else
        err "scripts/module.lds отсутствует или не содержит .plt секций! Это создаст 'module PLT section(s) missing' при сборке WiFi на плате."
    fi

    log "Готово. Дальше: $0 package"
}

# ---------------------------------------------------------------------------
# package: упаковать для переноса — БЕЗ clean, целиком
# ---------------------------------------------------------------------------
cmd_package() {
    [[ -f arch/arm64/boot/Image ]] || die "Image не найден — сначала: $0 build"

    local kver
    kver=$(cat include/config/kernel.release)
    log "== Упаковка для переноса на плату (версия $kver) =="

    local modpath="/tmp/modules_install_$kver"
    rm -rf "$modpath"
    mkdir -p "$modpath"
    make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" INSTALL_MOD_PATH="$modpath" modules_install 2>&1 | tee -a "$LOGFILE"

    local pkgdir="/tmp/kernel_package_$kver"
    rm -rf "$pkgdir"
    mkdir -p "$pkgdir/lib"
    cp -r "$modpath/lib/modules" "$pkgdir/lib/"
    cp arch/arm64/boot/Image "$pkgdir/"
    cp arch/arm64/boot/dts/rockchip/rk3576-rock-4d.dtb "$pkgdir/" 2>/dev/null || \
        log "Предупреждение: rk3576-rock-4d.dtb не найден по ожидаемому пути."
    cp arch/arm64/boot/dts/rockchip/rk3576-rock-4d-spi.dtb "$pkgdir/" 2>/dev/null || true
    cp .config "$pkgdir/config-plain"

    local out_boot="$HOME/ov9281-kernel-$kver.tar.gz"
    tar czf "$out_boot" -C "$pkgdir" .
    log "Пакет для /boot + модули: $out_boot"

    # Полное дерево БЕЗ clean — станет /usr/src/linux-headers-$kver на плате.
    local out_headers="$HOME/kernel-headers-$kver.tar.gz"
    local reponame
    reponame=$(basename "$(pwd)")
    ( cd .. && tar czf "$out_headers" "$reponame" )
    log "Пакет полного дерева (для DKMS/WiFi): $out_headers"
    log "ВНИМАНИЕ: это дерево весит несколько ГБ, т.к. содержит все .o/.ko — так и должно быть, не удаляйте их (clean)."

    cat << EOF

============================================================
 Готово. Перенос на плату:

   scp $out_boot $out_headers radxa@<IP_ПЛАТЫ>:~/

 На плате:

   KVER=$kver
   mkdir -p ~/ov9281_kernel_install
   tar xzf ~/ov9281-kernel-\$KVER.tar.gz -C ~/ov9281_kernel_install
   sudo cp -r ~/ov9281_kernel_install/lib/modules/\$KVER /lib/modules/
   sudo cp ~/ov9281_kernel_install/Image /boot/vmlinuz-\$KVER
   sudo mkdir -p /usr/lib/linux-image-\$KVER/rockchip/
   sudo cp ~/ov9281_kernel_install/rk3576-rock-4d*.dtb /usr/lib/linux-image-\$KVER/rockchip/
   sudo cp ~/ov9281_kernel_install/config-plain /boot/config-\$KVER
   sudo update-initramfs -c -k \$KVER
   sudo u-boot-update

   # Настоящее дерево для DKMS (обязательно, иначе WiFi не соберётся правильно):
   tar xzf ~/kernel-headers-\$KVER.tar.gz -C ~
   sudo rm -rf /usr/src/linux-headers-\$KVER
   sudo mv ~/$reponame /usr/src/linux-headers-\$KVER

   # Overlay камеры:
   sudo dtc -@ -I dts -O dtb -o /tmp/rock-4d-ov9281.dtbo overlay/rock4d-ov9281.dts
   sudo cp /tmp/rock-4d-ov9281.dtbo /boot/dtbo/rock-4d-ov9281.dtbo
   sudo mv /boot/dtbo/rock-4d-rpi-camera-v1_3.dtbo /boot/dtbo/rock-4d-rpi-camera-v1_3.dtbo.disabled 2>/dev/null

   # Сделать новое ядро загрузкой по умолчанию, затем:
   sudo u-boot-update
   sudo reboot

 После перезагрузки — WiFi (aic8800) через DKMS, используя настоящее
 дерево заголовков из /usr/src/linux-headers-\$KVER:
   sudo dkms status
   sudo dkms build   -m aic8800-usb -v <версия> -k \$KVER --force
   sudo dkms install -m aic8800-usb -v <версия> -k \$KVER --force
   # Если "module PLT section(s) missing" — module.lds всё же не сохранился,
   # пересоздайте его вручную (см. rock4d_wsl_build_guide.md, раздел 8).
============================================================
EOF
}

main() {
    case "${1:-}" in
        check)   cmd_check ;;
        build)   cmd_build ;;
        package) cmd_package ;;
        "")
            cat << 'EOF'
Использование:
  ./build_wsl_ov9281.sh check     # проверить состояние дерева перед сборкой
  ./build_wsl_ov9281.sh build     # собрать Image+modules+dtbs
  ./build_wsl_ov9281.sh package   # упаковать для переноса на плату (без clean!)
EOF
            ;;
        *)
            die "Неизвестная команда: $1"
            ;;
    esac
}

main "$@"
