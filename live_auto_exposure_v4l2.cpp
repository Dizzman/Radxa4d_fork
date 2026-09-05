// live_auto_exposure_v4l2.cpp
//
// Прямое чтение кадров с камеры OV9281 через "сырой" V4L2 API
// (mmap-стриминг), БЕЗ GStreamer — устраняет нестабильность, которую
// давал GStreamer/gst-inspect-1.0 (крахи, падения X).
//
// Формат захвата: NV12 (Y-плоскость несёт яркость; т.к. OV9281 —
// монохромный сенсор, UV-плоскость плоская/серая — не используется).
// Отображение: SDL2, напрямую как NV12-текстура (SDL_UpdateNVTexture),
// без ручной конвертации цвета.
//
// Автоэкспозиция: усредняем яркость по Y-плоскости, подстраиваем
// V4L2_CID_EXPOSURE и analogue_gain через VIDIOC_S_CTRL.
//
// Сборка:
//   g++ -O2 -std=c++17 live_auto_exposure_v4l2.cpp -o live_auto_exposure_v4l2 $(pkg-config --cflags --libs sdl2)
//
// Запуск:
//   ./live_auto_exposure_v4l2 [/dev/video11]
//
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <cerrno>
#include <string>
#include <vector>
#include <algorithm>
#include <chrono>

#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <poll.h>
#include <linux/videodev2.h>

#include <SDL2/SDL.h>
#include <SDL2/SDL_ttf.h>

// --- Параметры, специфичные для OV9281 (см. историю проекта) ---------------
// V4L2_CID_EXPOSURE — стандартный контрол (0x00980911), диапазон реально
// подтверждён на плате: min=4, max=3652 (30fps-режим), default=800.
static const int EXPOSURE_MIN = 4;
static const int EXPOSURE_MAX = 3652;

// analogue_gain — вендорский контрол Rockchip/OV9281, ID подтверждён на
// плате как 0x009e0903, диапазон min=16, max=248 (нет стандартного
// V4L2_CID_GAIN для этого сенсора).
static const unsigned int CID_ANALOGUE_GAIN = 0x009e0903;
static const int GAIN_MIN = 16;
static const int GAIN_MAX = 248;

static const int TARGET_BRIGHTNESS = 110;   // целевая средняя яркость (0-255)
static const int BRIGHTNESS_TOLERANCE = 8;  // не подстраиваем внутри +-этого

// ----------------------------------------------------------------------------

struct MappedBuffer {
    void   *start = nullptr;
    size_t  length = 0;
};

static int xioctl(int fd, unsigned long request, void *arg) {
    int r;
    do {
        r = ioctl(fd, request, arg);
    } while (r == -1 && errno == EINTR);
    return r;
}

static bool setControl(int fd, unsigned int id, int value) {
    struct v4l2_control ctrl {};
    ctrl.id = id;
    ctrl.value = value;
    if (xioctl(fd, VIDIOC_S_CTRL, &ctrl) == -1) {
        // Не считаем это фатальной ошибкой — только предупреждение,
        // некоторые значения могут быть временно недоступны.
        fprintf(stderr, "VIDIOC_S_CTRL (id=0x%x, value=%d): %s\n",
                id, value, strerror(errno));
        return false;
    }
    return true;
}

int main(int argc, char **argv) {
    if (argc > 1 && (std::string(argv[1]) == "--help" || std::string(argv[1]) == "-h")) {
        printf("Использование: %s [устройство_видео] [subdev_сенсора]\n", argv[0]);
        printf("  устройство_видео  — узел захвата ISP (по умолчанию: /dev/video11)\n");
        printf("  subdev_сенсора    — subdev для контролов экспозиции/усиления (по умолчанию: /dev/v4l-subdev3)\n");
        printf("Пример: %s /dev/video11 /dev/v4l-subdev3\n", argv[0]);
        return 0;
    }

    std::string devPath    = (argc > 1) ? argv[1] : "/dev/video11";
    // controls (V4L2_CID_EXPOSURE, analogue_gain) принадлежат subdev
    // САМОГО СЕНСОРА, а не узлу вывода ISP (/dev/video11) — это разные
    // устройства в медиа-графе. Подтверждено ошибкой "Invalid argument"
    // при попытке отправить их на /dev/video11.
    std::string subdevPath = (argc > 2) ? argv[2] : "/dev/v4l-subdev3";

    printf("Камера (захват):      %s\n", devPath.c_str());
    printf("Камера (subdev/exp):  %s\n", subdevPath.c_str());

    const int width  = 1280;
    const int height = 800;

    // --- Открытие устройства вывода (ISP) -------------------------------
    int fd = open(devPath.c_str(), O_RDWR | O_NONBLOCK);
    if (fd < 0) {
        fprintf(stderr, "Не удалось открыть %s: %s\n", devPath.c_str(), strerror(errno));
        return 1;
    }

    // --- Открытие subdev сенсора (для VIDIOC_S_CTRL: экспозиция/усиление) ---
    int subdevFd = open(subdevPath.c_str(), O_RDWR);
    if (subdevFd < 0) {
        fprintf(stderr, "Не удалось открыть %s (subdev сенсора для контролов): %s\n",
                subdevPath.c_str(), strerror(errno));
        fprintf(stderr, "Уточните путь: media-ctl -d /dev/media0 -p | grep -B2 m00_b_ov9281\n");
        close(fd);
        return 1;
    }

    struct v4l2_capability cap {};
    if (xioctl(fd, VIDIOC_QUERYCAP, &cap) == -1) {
        fprintf(stderr, "VIDIOC_QUERYCAP: %s\n", strerror(errno));
        close(fd);
        return 1;
    }
    printf("Устройство: %s (driver: %s)\n", cap.card, cap.driver);

    // rkisp_mainpath — MULTIPLANAR устройство (подтверждено выводом
    // v4l2-ctl: "Format Video Capture Multiplanar"), а не обычное
    // V4L2_BUF_TYPE_VIDEO_CAPTURE. С однoплоскостным типом VIDIOC_S_FMT
    // возвращал "Invalid argument" — сама ошибка была именно в этом,
    // разрешение 1280x800 тут ни при чём (оно и так корректно).
    const enum v4l2_buf_type CAPTURE_TYPE = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;

    // --- Установка формата захвата (NV12, multiplanar) ---------------------
    struct v4l2_format fmt {};
    fmt.type = CAPTURE_TYPE;
    fmt.fmt.pix_mp.width       = width;
    fmt.fmt.pix_mp.height      = height;
    fmt.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_NV12;
    fmt.fmt.pix_mp.field       = V4L2_FIELD_NONE;
    fmt.fmt.pix_mp.num_planes  = 1;   // драйвер пакует Y+UV в один буфер
    if (xioctl(fd, VIDIOC_S_FMT, &fmt) == -1) {
        fprintf(stderr, "VIDIOC_S_FMT: %s\n", strerror(errno));
        close(fd);
        return 1;
    }
    if (fmt.fmt.pix_mp.pixelformat != V4L2_PIX_FMT_NV12) {
        fprintf(stderr, "Драйвер не согласился на NV12 — получили другой формат.\n");
    }
    const int actualWidth   = fmt.fmt.pix_mp.width;
    const int actualHeight  = fmt.fmt.pix_mp.height;
    const int numPlanes     = fmt.fmt.pix_mp.num_planes;
    const int yStride       = fmt.fmt.pix_mp.plane_fmt[0].bytesperline
                                   ? fmt.fmt.pix_mp.plane_fmt[0].bytesperline : actualWidth;
    printf("Формат захвата: %dx%d, planes=%d, bytesperline=%d\n",
           actualWidth, actualHeight, numPlanes, yStride);

    // --- Запрос буферов (mmap, multiplanar) ---------------------------------
    const unsigned int NUM_BUFFERS = 4;
    struct v4l2_requestbuffers req {};
    req.count  = NUM_BUFFERS;
    req.type   = CAPTURE_TYPE;
    req.memory = V4L2_MEMORY_MMAP;
    if (xioctl(fd, VIDIOC_REQBUFS, &req) == -1) {
        fprintf(stderr, "VIDIOC_REQBUFS: %s\n", strerror(errno));
        close(fd);
        return 1;
    }
    if (req.count < 2) {
        fprintf(stderr, "Драйвер выделил слишком мало буферов (%u).\n", req.count);
        close(fd);
        return 1;
    }

    // В multiplanar API каждый v4l2_buffer описывает НЕСКОЛЬКО плоскостей
    // через отдельный массив v4l2_plane[] — даже если num_planes=1, этот
    // массив всё равно обязателен (m.planes должен указывать на него).
    std::vector<MappedBuffer> buffers(req.count);
    for (unsigned int i = 0; i < req.count; ++i) {
        struct v4l2_plane planes[VIDEO_MAX_PLANES] {};
        struct v4l2_buffer buf {};
        buf.type     = CAPTURE_TYPE;
        buf.memory   = V4L2_MEMORY_MMAP;
        buf.index    = i;
        buf.length   = numPlanes;
        buf.m.planes = planes;
        if (xioctl(fd, VIDIOC_QUERYBUF, &buf) == -1) {
            fprintf(stderr, "VIDIOC_QUERYBUF: %s\n", strerror(errno));
            close(fd);
            return 1;
        }
        buffers[i].length = planes[0].length;
        buffers[i].start = mmap(nullptr, planes[0].length, PROT_READ | PROT_WRITE,
                                 MAP_SHARED, fd, planes[0].m.mem_offset);
        if (buffers[i].start == MAP_FAILED) {
            fprintf(stderr, "mmap: %s\n", strerror(errno));
            close(fd);
            return 1;
        }
    }

    // Ставим все буферы в очередь на заполнение.
    for (unsigned int i = 0; i < req.count; ++i) {
        struct v4l2_plane planes[VIDEO_MAX_PLANES] {};
        struct v4l2_buffer buf {};
        buf.type     = CAPTURE_TYPE;
        buf.memory   = V4L2_MEMORY_MMAP;
        buf.index    = i;
        buf.length   = numPlanes;
        buf.m.planes = planes;
        if (xioctl(fd, VIDIOC_QBUF, &buf) == -1) {
            fprintf(stderr, "VIDIOC_QBUF (init): %s\n", strerror(errno));
            close(fd);
            return 1;
        }
    }

    // --- Запуск стриминга --------------------------------------------------
    enum v4l2_buf_type bufType = CAPTURE_TYPE;
    if (xioctl(fd, VIDIOC_STREAMON, &bufType) == -1) {
        fprintf(stderr, "VIDIOC_STREAMON: %s\n", strerror(errno));
        close(fd);
        return 1;
    }

    // --- Инициализация SDL2 -------------------------------------------------
    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        close(fd);
        return 1;
    }

    SDL_Window *window = SDL_CreateWindow(
        "OV9281 — live (V4L2 + SDL2, автоэкспозиция)",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        actualWidth, actualHeight, SDL_WINDOW_SHOWN);
    if (!window) {
        fprintf(stderr, "SDL_CreateWindow: %s\n", SDL_GetError());
        SDL_Quit();
        close(fd);
        return 1;
    }

    SDL_Renderer *renderer = SDL_CreateRenderer(
        window, -1, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    if (!renderer) {
        // Запасной вариант без аппаратного ускорения — на некоторых
        // системах (без рабочего GPU-драйвера) accelerated может не быть.
        renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_SOFTWARE);
    }
    if (!renderer) {
        fprintf(stderr, "SDL_CreateRenderer: %s\n", SDL_GetError());
        SDL_DestroyWindow(window);
        SDL_Quit();
        close(fd);
        return 1;
    }

    SDL_Texture *texture = SDL_CreateTexture(
        renderer, SDL_PIXELFORMAT_NV12, SDL_TEXTUREACCESS_STREAMING,
        actualWidth, actualHeight);
    if (!texture) {
        fprintf(stderr, "SDL_CreateTexture (NV12): %s\n", SDL_GetError());
        SDL_DestroyRenderer(renderer);
        SDL_DestroyWindow(window);
        SDL_Quit();
        close(fd);
        return 1;
    }

    // --- Инициализация SDL_ttf для отрисовки FPS ПРЯМО НА КАДРЕ ------------
    TTF_Font *font = nullptr;
    if (TTF_Init() != 0) {
        fprintf(stderr, "TTF_Init: %s (FPS будет только в консоли)\n", TTF_GetError());
    } else {
        // Перебираем несколько типичных путей к шрифту — точное имя
        // пакета/пути к DejaVuSans может отличаться между дистрибутивами.
        static const char *fontPaths[] = {
            "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
        };
        for (const char *p : fontPaths) {
            font = TTF_OpenFont(p, 22);
            if (font) break;
        }
        if (!font) {
            fprintf(stderr, "Не найден шрифт DejaVuSans — FPS будет только в консоли.\n");
        }
    }

    // Текущие значения контролов (стартуем с дефолтов сенсора).
    int currentExposure = 800;
    int currentGain     = 16;
    setControl(subdevFd, V4L2_CID_EXPOSURE, currentExposure);
    setControl(subdevFd, CID_ANALOGUE_GAIN, currentGain);

    printf("Запуск. Закройте окно или нажмите ESC для выхода.\n");

    // --- Подсчёт FPS: считаем кадры, раз в секунду печатаем и сбрасываем ---
    int fpsFrameCount = 0;
    auto fpsLastTime = std::chrono::steady_clock::now();
    double currentFps = 0.0;

    bool running = true;
    while (running) {
        // --- Обработка событий SDL (закрытие окна / ESC) ---
        SDL_Event ev;
        while (SDL_PollEvent(&ev)) {
            if (ev.type == SDL_QUIT) running = false;
            if (ev.type == SDL_KEYDOWN && ev.key.keysym.sym == SDLK_ESCAPE) running = false;
        }
        if (!running) break;

        // --- Ждём готовый кадр (poll с таймаутом, чтобы не блокироваться
        // навечно, если камера вдруг перестала присылать кадры) ---
        struct pollfd pfd { fd, POLLIN, 0 };
        int pr = poll(&pfd, 1, 1000 /* мс */);
        if (pr < 0) {
            if (errno == EINTR) continue;
            fprintf(stderr, "poll: %s\n", strerror(errno));
            break;
        }
        if (pr == 0) {
            fprintf(stderr, "Таймаут ожидания кадра (1с) — камера не отвечает?\n");
            continue;
        }

        struct v4l2_plane planes[VIDEO_MAX_PLANES] {};
        struct v4l2_buffer buf {};
        buf.type     = CAPTURE_TYPE;
        buf.memory   = V4L2_MEMORY_MMAP;
        buf.length   = numPlanes;
        buf.m.planes = planes;
        if (xioctl(fd, VIDIOC_DQBUF, &buf) == -1) {
            if (errno == EAGAIN) continue;
            fprintf(stderr, "VIDIOC_DQBUF: %s\n", strerror(errno));
            break;
        }

        const uint8_t *yPlane  = static_cast<const uint8_t *>(buffers[buf.index].start);
        const uint8_t *uvPlane = yPlane + (size_t)yStride * actualHeight;

        // --- Автоэкспозиция: усредняем яркость по разреженной выборке
        // пикселей Y-плоскости (не по каждому — для скорости) ---
        long sum = 0;
        int  count = 0;
        const int stepX = 8, stepY = 8;
        for (int y = 0; y < actualHeight; y += stepY) {
            const uint8_t *row = yPlane + (size_t)y * yStride;
            for (int x = 0; x < actualWidth; x += stepX) {
                sum += row[x];
                ++count;
            }
        }
        int avgBrightness = count ? (int)(sum / count) : 0;

        int diff = TARGET_BRIGHTNESS - avgBrightness;
        if (diff > BRIGHTNESS_TOLERANCE || diff < -BRIGHTNESS_TOLERANCE) {
            // Сначала подстраиваем выдержку (более тонкий инструмент),
            // и только если она уже упёрлась в границу диапазона —
            // компенсируем усилением (gain).
            int step = diff / 4;   // плавная подстройка, не рывками
            if (step == 0) step = (diff > 0) ? 1 : -1;

            int newExposure = std::clamp(currentExposure + step * 20,
                                          EXPOSURE_MIN, EXPOSURE_MAX);
            if (newExposure != currentExposure) {
                currentExposure = newExposure;
                setControl(subdevFd, V4L2_CID_EXPOSURE, currentExposure);
            } else {
                // Выдержка уже на границе — подстраиваем gain.
                int newGain = std::clamp(currentGain + step,
                                          GAIN_MIN, GAIN_MAX);
                if (newGain != currentGain) {
                    currentGain = newGain;
                    setControl(subdevFd, CID_ANALOGUE_GAIN, currentGain);
                }
            }
        }

        // --- FPS: раз в секунду печатаем в консоль/заголовок, обновляем
        // currentFps (используется ниже для отрисовки на КАЖДОМ кадре) ---
        ++fpsFrameCount;
        auto now = std::chrono::steady_clock::now();
        double elapsed = std::chrono::duration<double>(now - fpsLastTime).count();
        if (elapsed >= 1.0) {
            currentFps = fpsFrameCount / elapsed;
            printf("FPS: %.1f (кадров за %.2fс: %d) | exp=%d gain=%d\n",
                   currentFps, elapsed, fpsFrameCount, currentExposure, currentGain);
            char title[128];
            snprintf(title, sizeof(title),
                     "OV9281 — live (V4L2 + SDL2) | FPS: %.1f | exp=%d gain=%d",
                     currentFps, currentExposure, currentGain);
            SDL_SetWindowTitle(window, title);
            fpsFrameCount = 0;
            fpsLastTime = now;
        }

        // --- Отображение кадра через SDL2 (напрямую NV12, без конвертации) ---
        SDL_UpdateNVTexture(texture, nullptr,
                             yPlane, yStride,
                             uvPlane, yStride);
        SDL_RenderClear(renderer);
        SDL_RenderCopy(renderer, texture, nullptr, nullptr);

        // --- Оверлей FPS ПРЯМО НА КАДРЕ (не только в заголовке окна) ---
        if (font) {
            char fpsText[64];
            snprintf(fpsText, sizeof(fpsText), "FPS: %.1f  exp=%d gain=%d",
                      currentFps, currentExposure, currentGain);
            SDL_Color white { 255, 255, 255, 255 };
            SDL_Surface *textSurf = TTF_RenderText_Blended(font, fpsText, white);
            if (textSurf) {
                SDL_Texture *textTex = SDL_CreateTextureFromSurface(renderer, textSurf);
                if (textTex) {
                    SDL_Rect dst { 10, 10, textSurf->w, textSurf->h };
                    SDL_RenderCopy(renderer, textTex, nullptr, &dst);
                    SDL_DestroyTexture(textTex);
                }
                SDL_FreeSurface(textSurf);
            }
        }

        SDL_RenderPresent(renderer);

        // --- Возвращаем буфер в очередь драйвера ---
        if (xioctl(fd, VIDIOC_QBUF, &buf) == -1) {
            fprintf(stderr, "VIDIOC_QBUF: %s\n", strerror(errno));
            break;
        }
    }

    // --- Остановка и освобождение ресурсов ---
    xioctl(fd, VIDIOC_STREAMOFF, &bufType);
    for (auto &b : buffers) {
        if (b.start && b.start != MAP_FAILED) munmap(b.start, b.length);
    }
    SDL_DestroyTexture(texture);
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    if (font) TTF_CloseFont(font);
    TTF_Quit();
    SDL_Quit();
    close(fd);
    close(subdevFd);

    printf("Завершено.\n");
    return 0;
}
