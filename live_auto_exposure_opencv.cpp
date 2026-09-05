// live_auto_exposure_opencv.cpp
//
// То же самое, что live_auto_exposure_v4l2.cpp — прямое чтение кадров
// через "сырой" V4L2 API (mmap-стриминг), БЕЗ GStreamer — но отображение
// через OpenCV (cv::imshow) вместо SDL2.
//
// Т.к. OV9281 — монохромный сенсор, Y-плоскость NV12-буфера уже несёт
// готовое чёрно-белое изображение — оборачиваем её напрямую в cv::Mat
// БЕЗ копирования памяти (zero-copy), конвертация цвета не нужна.
//
// Сборка:
//   g++ -O2 -std=c++17 live_auto_exposure_opencv.cpp -o live_auto_exposure_opencv $(pkg-config --cflags --libs opencv4)
//   (если pkg-config не находит opencv4, попробуйте: opencv, или укажите путь вручную)
//
// Запуск:
//   ./live_auto_exposure_opencv [/dev/video11]
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

#include <opencv2/opencv.hpp>

// --- Параметры, специфичные для OV9281 (см. историю проекта) ---------------
static const int EXPOSURE_MIN = 4;
static const int EXPOSURE_MAX = 3652;

static const unsigned int CID_ANALOGUE_GAIN = 0x009e0903;
static const int GAIN_MIN = 16;
static const int GAIN_MAX = 248;

static const int TARGET_BRIGHTNESS = 110;
static const int BRIGHTNESS_TOLERANCE = 8;

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
        fprintf(stderr, "VIDIOC_S_CTRL (id=0x%x, value=%d): %s\n",
                id, value, strerror(errno));
        return false;
    }
    return true;
}

int main(int argc, char **argv) {
    // --- Аргументы командной строки: явное указание камеры и её subdev ---
    if (argc > 1 && (std::string(argv[1]) == "--help" || std::string(argv[1]) == "-h")) {
        printf("Использование: %s [устройство_видео] [subdev_сенсора]\n", argv[0]);
        printf("  устройство_видео  — узел захвата ISP (по умолчанию: /dev/video11)\n");
        printf("  subdev_сенсора    — subdev для контролов экспозиции/усиления (по умолчанию: /dev/v4l-subdev3)\n");
        printf("Пример: %s /dev/video11 /dev/v4l-subdev3\n", argv[0]);
        return 0;
    }

    std::string devPath    = (argc > 1) ? argv[1] : "/dev/video11";
    // controls (V4L2_CID_EXPOSURE, analogue_gain) принадлежат subdev
    // САМОГО СЕНСОРА, а не узлу вывода ISP (/dev/video11).
    std::string subdevPath = (argc > 2) ? argv[2] : "/dev/v4l-subdev3";

    printf("Камера (захват):      %s\n", devPath.c_str());
    printf("Камера (subdev/exp):  %s\n", subdevPath.c_str());

    const int width  = 1280;
    const int height = 800;

    int fd = open(devPath.c_str(), O_RDWR | O_NONBLOCK);
    if (fd < 0) {
        fprintf(stderr, "Не удалось открыть %s: %s\n", devPath.c_str(), strerror(errno));
        return 1;
    }

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
    // возвращал "Invalid argument".
    const enum v4l2_buf_type CAPTURE_TYPE = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;

    struct v4l2_format fmt {};
    fmt.type = CAPTURE_TYPE;
    fmt.fmt.pix_mp.width       = width;
    fmt.fmt.pix_mp.height      = height;
    fmt.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_NV12;
    fmt.fmt.pix_mp.field       = V4L2_FIELD_NONE;
    fmt.fmt.pix_mp.num_planes  = 1;
    if (xioctl(fd, VIDIOC_S_FMT, &fmt) == -1) {
        fprintf(stderr, "VIDIOC_S_FMT: %s\n", strerror(errno));
        close(fd);
        return 1;
    }
    const int actualWidth  = fmt.fmt.pix_mp.width;
    const int actualHeight = fmt.fmt.pix_mp.height;
    const int numPlanes    = fmt.fmt.pix_mp.num_planes;
    const int yStride      = fmt.fmt.pix_mp.plane_fmt[0].bytesperline
                                  ? fmt.fmt.pix_mp.plane_fmt[0].bytesperline : actualWidth;
    printf("Формат захвата: %dx%d, planes=%d, bytesperline=%d\n",
           actualWidth, actualHeight, numPlanes, yStride);

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

    enum v4l2_buf_type bufType = CAPTURE_TYPE;
    if (xioctl(fd, VIDIOC_STREAMON, &bufType) == -1) {
        fprintf(stderr, "VIDIOC_STREAMON: %s\n", strerror(errno));
        close(fd);
        return 1;
    }

    // --- Окно OpenCV ---------------------------------------------------
    const std::string windowName = "OV9281 - live (V4L2 + OpenCV, автоэкспозиция)";
    cv::namedWindow(windowName, cv::WINDOW_AUTOSIZE);

    int currentExposure = 800;
    int currentGain     = 16;
    setControl(subdevFd, V4L2_CID_EXPOSURE, currentExposure);
    setControl(subdevFd, CID_ANALOGUE_GAIN, currentGain);

    printf("Запуск. Нажмите ESC или 'q' в окне для выхода.\n");

    // --- Подсчёт FPS: считаем кадры, раз в секунду обновляем displayFps ---
    int fpsFrameCount = 0;
    auto fpsLastTime = std::chrono::steady_clock::now();
    double displayFps = 0.0;   // текущее значение FPS для отрисовки на каждом кадре

    bool running = true;
    while (running) {
        struct pollfd pfd { fd, POLLIN, 0 };
        int pr = poll(&pfd, 1, 1000);
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

        uint8_t *yPlane = static_cast<uint8_t *>(buffers[buf.index].start);

        // Оборачиваем Y-плоскость в cv::Mat БЕЗ копирования памяти —
        // третий/четвёртый аргумент (data, step) заставляют cv::Mat
        // использовать уже существующий буфер как есть.
        cv::Mat gray(actualHeight, actualWidth, CV_8UC1, yPlane, yStride);

        // --- Автоэкспозиция: cv::mean() сам эффективно считает среднюю
        // яркость по всему изображению (внутри векторизовано) ---
        double avgBrightness = cv::mean(gray)[0];

        int diff = TARGET_BRIGHTNESS - (int)avgBrightness;
        if (diff > BRIGHTNESS_TOLERANCE || diff < -BRIGHTNESS_TOLERANCE) {
            int step = diff / 4;
            if (step == 0) step = (diff > 0) ? 1 : -1;

            int newExposure = std::clamp(currentExposure + step * 20,
                                          EXPOSURE_MIN, EXPOSURE_MAX);
            if (newExposure != currentExposure) {
                currentExposure = newExposure;
                setControl(subdevFd, V4L2_CID_EXPOSURE, currentExposure);
            } else {
                int newGain = std::clamp(currentGain + step,
                                          GAIN_MIN, GAIN_MAX);
                if (newGain != currentGain) {
                    currentGain = newGain;
                    setControl(subdevFd, CID_ANALOGUE_GAIN, currentGain);
                }
            }
        }

        // --- FPS: раз в секунду обновляем displayFps (используется ниже
        // для отрисовки на КАЖДОМ кадре, не только раз в секунду) ---
        ++fpsFrameCount;
        auto now = std::chrono::steady_clock::now();
        double elapsed = std::chrono::duration<double>(now - fpsLastTime).count();
        if (elapsed >= 1.0) {
            displayFps = fpsFrameCount / elapsed;
            printf("FPS: %.1f (кадров за %.2fс: %d) | exp=%d gain=%d\n",
                   displayFps, elapsed, fpsFrameCount, currentExposure, currentGain);
            fpsFrameCount = 0;
            fpsLastTime = now;
        }

        // --- Оверлей FPS ПРЯМО НА КАДРЕ (не только в консоли) ---
        // Клонируем перед рисованием — gray оборачивает буфер драйвера
        // напрямую (zero-copy), рисовать поверх него без клонирования
        // тоже безопасно (буфер снова уйдёт в очередь и будет перезаписан
        // новым кадром), но клонирование чуть безопаснее и не влияет
        // на производительность заметно при таком разрешении.
        cv::Mat displayFrame = gray.clone();
        char fpsText[64];
        snprintf(fpsText, sizeof(fpsText), "FPS: %.1f  exp=%d gain=%d",
                 displayFps, currentExposure, currentGain);
        cv::putText(displayFrame, fpsText, cv::Point(10, 30),
                    cv::FONT_HERSHEY_SIMPLEX, 0.8, cv::Scalar(255), 2);

        cv::imshow(windowName, displayFrame);
        int key = cv::waitKey(1);
        if (key == 27 /* ESC */ || key == 'q') running = false;

        if (xioctl(fd, VIDIOC_QBUF, &buf) == -1) {
            fprintf(stderr, "VIDIOC_QBUF: %s\n", strerror(errno));
            break;
        }
    }

    xioctl(fd, VIDIOC_STREAMOFF, &bufType);
    for (auto &b : buffers) {
        if (b.start && b.start != MAP_FAILED) munmap(b.start, b.length);
    }
    cv::destroyAllWindows();
    close(fd);
    close(subdevFd);

    printf("Завершено.\n");
    return 0;
}
