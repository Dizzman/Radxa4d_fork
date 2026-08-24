// live_auto_exposure.cpp
//
// Живой просмотр камеры OV9281 на Radxa ROCK 4D + быстрая автоматическая
// регулировка яркости (exposure/gain) напрямую через ioctl
// (V4L2_CID_EXPOSURE / V4L2_CID_ANALOGUE_GAIN), без запуска внешних
// процессов (в отличие от python-версии, которая дергала v4l2-ctl через
// subprocess).
//
// Один GStreamer pipeline: v4l2src -> tee -> [xvimagesink, appsink].
// Ветка appsink анализирует яркость Y-плоскости NV12 и сразу пишет новые
// exposure/gain через ioctl(VIDIOC_S_CTRL) на /dev/v4l-subdev3.
//
// ВАЖНО (специфика OV9281 на этой плате, см. README.md):
//  - Родное разрешение сенсора: 1280x800 (не 3280x2464, как у IMX219!)
//  - Единственный практически доступный framerate main-path (rkisp) — 30fps.
//    Сенсор объявляет поддержку 120fps на уровне subdev, но
//    VIDIOC_SUBDEV_S_FRAME_INTERVAL не реализован в текущем драйвере,
//    поэтому реального переключения добиться не удалось.
//  - Controls другие, чем у IMX219: нет V4L2_CID_GAIN, есть
//    V4L2_CID_ANALOGUE_GAIN с диапазоном 16-248 (а не тысячи).
//    exposure: 4-3652.
//
// Сборка:
//   g++ -O2 -std=c++17 live_auto_exposure.cpp -o live_auto_exposure \
//       $(pkg-config --cflags --libs gstreamer-1.0 gstreamer-app-1.0)
//
// Запуск (на плате, монитор подключён к HDMI, рабочий стол уже поднят):
//   export DISPLAY=:1   # номер дисплея уточнить через `who`/`w`
//   ./live_auto_exposure
//
// Остановка: Ctrl+C
#include <gst/gst.h>
#include <gst/app/gstappsink.h>
#include <linux/videodev2.h>
#include <sys/ioctl.h>
#include <fcntl.h>
#include <unistd.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <csignal>

// ---------- Настройки ----------
static const char* VIDEO_DEV = "/dev/video11";   // rkisp_mainpath
static const char* SUBDEV    = "/dev/v4l-subdev3"; // проверить: v4l2-ctl -d /dev/v4l-subdev3 --info

static const int WIDTH  = 1280;   // родное разрешение OV9281
static const int HEIGHT = 800;
static const int FRAMERATE = 30;  // 120fps объявлены сенсором, но main-path
                                   // реально согласует только 30 (см. README)

static const double TARGET_BRIGHTNESS = 110.0;
static const double TOLERANCE = 15.0;
static const int SAMPLE_STRIDE = 50; // берём каждый 50-й байт Y-плоскости для скорости

// Диапазоны controls реального OV9281 (см. v4l2-ctl -d /dev/v4l-subdev3 --list-ctrls)
static const int EXPOSURE_MIN = 4,   EXPOSURE_MAX = 3652;
static const int GAIN_MIN     = 16,  GAIN_MAX     = 248;

static std::atomic<int> g_exposure{800};
static std::atomic<int> g_gain{100};

static int g_subdev_fd = -1;
static GMainLoop* g_loop = nullptr;
static std::atomic<long> g_frame_count{0};
static GstElement* g_fps_overlay = nullptr;
// --------------------------------

static bool set_ctrl(int fd, unsigned int id, int value) {
    struct v4l2_control ctrl;
    std::memset(&ctrl, 0, sizeof(ctrl));
    ctrl.id = id;
    ctrl.value = value;
    if (ioctl(fd, VIDIOC_S_CTRL, &ctrl) < 0) {
        std::perror("VIDIOC_S_CTRL");
        return false;
    }
    return true;
}

static void apply_sensor_ctrl(int exposure, int gain) {
    if (g_subdev_fd < 0) return;
    set_ctrl(g_subdev_fd, V4L2_CID_EXPOSURE, exposure);
    set_ctrl(g_subdev_fd, V4L2_CID_ANALOGUE_GAIN, gain); // не V4L2_CID_GAIN! у OV9281 его нет
}

static int clampi(int v, int lo, int hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

static void adjust_exposure(double brightness) {
    int exposure = g_exposure.load();
    int gain = g_gain.load();
    double diff = TARGET_BRIGHTNESS - brightness;

    if (std::abs(diff) <= TOLERANCE) {
        std::printf("Яркость %.1f — в норме. (exposure=%d, gain=%d)\n",
                     brightness, exposure, gain);
        return;
    }

    // Пропорциональный регулятор: шаг пропорционален отклонению от цели,
    // чтобы не "перелетать" через целевую яркость и не колебаться туда-сюда.
    //
    // ВАЖНО: коэффициенты подобраны под реальный диапазон analogue_gain
    // OV9281 (16-248, всего 232 шага). Если взять коэффициенты, рассчитанные
    // под IMX219 (диапазон был 256-30000), регулятор гарантированно будет
    // перелетать через цель и уходить в устойчивую осцилляцию между
    // крайними значениями (16 <-> 248) — именно так и было при отладке.
    const double K_GAIN = 0.3;       // коэффициент усиления регулятора по gain
    const int MAX_GAIN_STEP = 20;    // ограничение максимального шага за итерацию
    int gain_step = static_cast<int>(diff * K_GAIN);
    gain_step = clampi(gain_step, -MAX_GAIN_STEP, MAX_GAIN_STEP);
    int new_gain = clampi(gain + gain_step, GAIN_MIN, GAIN_MAX);

    // Если gain уже уперся в границу диапазона и этого недостаточно —
    // начинаем плавно подстраивать exposure тем же принципом.
    if (new_gain == gain) {
        const double K_EXPOSURE = 3.0;
        const int MAX_EXPOSURE_STEP = 200;
        int exp_step = static_cast<int>(diff * K_EXPOSURE);
        exp_step = clampi(exp_step, -MAX_EXPOSURE_STEP, MAX_EXPOSURE_STEP);
        exposure = clampi(exposure + exp_step, EXPOSURE_MIN, EXPOSURE_MAX);
    }

    gain = new_gain;
    g_exposure.store(exposure);
    g_gain.store(gain);
    apply_sensor_ctrl(exposure, gain);

    std::printf("Яркость %.1f -> подстраиваю (exposure=%d, gain=%d)\n",
                brightness, exposure, gain);
}

static GstFlowReturn on_new_sample(GstAppSink* sink, gpointer /*user_data*/) {
    g_frame_count.fetch_add(1, std::memory_order_relaxed);
    GstSample* sample = gst_app_sink_pull_sample(sink);
    if (!sample) return GST_FLOW_ERROR;

    GstBuffer* buf = gst_sample_get_buffer(sample);
    GstMapInfo map;
    if (buf && gst_buffer_map(buf, &map, GST_MAP_READ)) {
        size_t y_size = static_cast<size_t>(WIDTH) * static_cast<size_t>(HEIGHT);
        size_t n = std::min(y_size, static_cast<size_t>(map.size));
        long long sum = 0;
        size_t count = 0;
        for (size_t i = 0; i < n; i += SAMPLE_STRIDE) {
            sum += map.data[i];
            ++count;
        }
        if (count > 0) {
            double brightness = static_cast<double>(sum) / static_cast<double>(count);
            adjust_exposure(brightness);
        }
        gst_buffer_unmap(buf, &map);
    }

    gst_sample_unref(sample);
    return GST_FLOW_OK;
}

static gboolean on_bus_message(GstBus* /*bus*/, GstMessage* message, gpointer /*data*/) {
    switch (GST_MESSAGE_TYPE(message)) {
        case GST_MESSAGE_EOS:
            g_main_loop_quit(g_loop);
            break;
        case GST_MESSAGE_ERROR: {
            GError* err = nullptr;
            gchar* debug = nullptr;
            gst_message_parse_error(message, &err, &debug);
            std::fprintf(stderr, "Ошибка GStreamer: %s\n", err ? err->message : "unknown");
            if (err) g_error_free(err);
            if (debug) g_free(debug);
            g_main_loop_quit(g_loop);
            break;
        }
        default:
            break;
    }
    return TRUE;
}

static void handle_sigint(int) {
    if (g_loop) g_main_loop_quit(g_loop);
}

static gboolean on_fps_timer(gpointer /*data*/) {
    long frames = g_frame_count.exchange(0, std::memory_order_relaxed);
    std::printf("FPS: %ld\n", frames);
    if (g_fps_overlay) {
        char text[32];
        std::snprintf(text, sizeof(text), "FPS: %ld", frames);
        g_object_set(g_fps_overlay, "text", text, nullptr);
    }
    return TRUE; // повторять каждый интервал
}

int main(int argc, char** argv) {
    gst_init(&argc, &argv);

    g_subdev_fd = open(SUBDEV, O_RDWR);
    if (g_subdev_fd < 0) {
        std::perror("Не удалось открыть subdev");
        return 1;
    }
    apply_sensor_ctrl(g_exposure.load(), g_gain.load());

    char pipeline_desc[1024];
    std::snprintf(pipeline_desc, sizeof(pipeline_desc),
        "v4l2src device=%s ! "
        "video/x-raw,format=NV12,width=%d,height=%d,framerate=%d/1 ! "
        "tee name=t "
        "t. ! queue leaky=downstream max-size-buffers=3 ! "
        "textoverlay name=fpsoverlay text=\"FPS: --\" valignment=top halignment=right "
        "font-desc=\"Sans, 24\" shaded-background=true ! xvimagesink "
        "t. ! queue leaky=downstream max-size-buffers=3 ! "
        "appsink name=sink emit-signals=true max-buffers=1 drop=true sync=false",
        VIDEO_DEV, WIDTH, HEIGHT, FRAMERATE);

    GError* error = nullptr;
    GstElement* pipeline = gst_parse_launch(pipeline_desc, &error);
    if (!pipeline) {
        std::fprintf(stderr, "Не удалось собрать pipeline: %s\n",
                     error ? error->message : "unknown");
        if (error) g_error_free(error);
        close(g_subdev_fd);
        return 1;
    }

    GstElement* appsink_elem = gst_bin_get_by_name(GST_BIN(pipeline), "sink");
    g_signal_connect(appsink_elem, "new-sample", G_CALLBACK(on_new_sample), nullptr);

    g_fps_overlay = gst_bin_get_by_name(GST_BIN(pipeline), "fpsoverlay");

    GstBus* bus = gst_element_get_bus(pipeline);
    gst_bus_add_watch(bus, on_bus_message, nullptr);
    gst_object_unref(bus);

    gst_element_set_state(pipeline, GST_STATE_PLAYING);

    signal(SIGINT, handle_sigint);
    std::printf("Запущено. Ctrl+C для остановки.\n");

    g_loop = g_main_loop_new(nullptr, FALSE);
    g_timeout_add_seconds(1, on_fps_timer, nullptr);
    g_main_loop_run(g_loop);

    std::printf("\nОстановка...\n");
    gst_element_set_state(pipeline, GST_STATE_NULL);

    if (g_fps_overlay) gst_object_unref(g_fps_overlay);
    gst_object_unref(appsink_elem);
    gst_object_unref(pipeline);
    g_main_loop_unref(g_loop);
    close(g_subdev_fd);

    return 0;
}
