// fsd.cpp - thin C++ shim around stable-diffusion.cpp.
//
// Pinned upstream commit: see third_party/stable-diffusion.cpp (submodule).
// Keep the surface area minimal: only what lib/fsd.dart needs.

#include "fsd.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

#include "stable-diffusion.h"

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#ifdef __ANDROID__
#  include <android/log.h>
#  define FSD_LOG(...) __android_log_print(ANDROID_LOG_INFO, "fsd", __VA_ARGS__)
#else
#  include <cstdio>
#  define FSD_LOG(...) do { fprintf(stderr, "[fsd] " __VA_ARGS__); fputc('\n', stderr); } while (0)
#endif

struct fsd_ctx {
    sd_ctx_t* sd = nullptr;
    std::atomic<int> cancel_requested{0};
};

namespace {

// Single in-flight generation at a time (Dart helper isolate is single-threaded).
// The progress callback in stable-diffusion.cpp is a global hook, so we route
// it through this mutex-guarded slot. If a future iteration ever runs two
// generations in parallel (multiple ctxs / multiple isolates), this needs
// rework.
std::mutex g_active_mu;
fsd_ctx*     g_active_ctx  = nullptr;
fsd_step_cb  g_active_cb   = nullptr;
void*        g_active_user = nullptr;
bool         g_active_cancelled = false;

void sd_log_proxy(enum sd_log_level_t level, const char* text, void* /*data*/) {
    if (!text) return;
    // strip trailing newline for android logcat
    std::string s(text);
    while (!s.empty() && (s.back() == '\n' || s.back() == '\r')) s.pop_back();
    FSD_LOG("[sd:%d] %s", (int)level, s.c_str());
}

void sd_progress_proxy(int step, int steps, float /*time*/, void* /*data*/) {
    fsd_step_cb  cb = nullptr;
    void*        user = nullptr;
    fsd_ctx*     ctx = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_active_mu);
        cb   = g_active_cb;
        user = g_active_user;
        ctx  = g_active_ctx;
    }
    if (ctx && ctx->cancel_requested.load(std::memory_order_acquire)) {
        std::lock_guard<std::mutex> lk(g_active_mu);
        g_active_cancelled = true;
    }
    if (cb) {
        int keep_going = cb(step, steps, user);
        if (keep_going == 0) {
            std::lock_guard<std::mutex> lk(g_active_mu);
            g_active_cancelled = true;
        }
    }
    // Note: stable-diffusion.cpp ignores our return (the cb has void return).
    // The cancel flag is honoured by fsd_generate after generate_image
    // returns; the in-flight step cannot be interrupted.
}

void png_write_to_vec(void* ctx, void* data, int size) {
    auto* v = reinterpret_cast<std::vector<uint8_t>*>(ctx);
    v->insert(v->end(),
              reinterpret_cast<uint8_t*>(data),
              reinterpret_cast<uint8_t*>(data) + size);
}

bool g_log_installed = false;

}  // namespace

extern "C" {

FSD_API fsd_ctx* fsd_load(const char* model_path) {
    if (!model_path) return nullptr;

    if (!g_log_installed) {
        sd_set_log_callback(sd_log_proxy, nullptr);
        sd_set_progress_callback(sd_progress_proxy, nullptr);
        g_log_installed = true;
    }

    sd_ctx_params_t p;
    sd_ctx_params_init(&p);
    p.model_path             = model_path;
    p.vae_decode_only        = true;   // we never feed images back in
    p.free_params_immediately = false; // keep weights resident across generates
    p.n_threads              = -1;     // auto
    p.wtype                  = SD_TYPE_COUNT; // keep file's native dtype
    p.rng_type               = STD_DEFAULT_RNG;
    p.offload_params_to_cpu  = false;
    p.enable_mmap            = true;
    p.keep_clip_on_cpu       = false;
    p.keep_control_net_on_cpu = false;
    p.keep_vae_on_cpu        = false;
    p.flash_attn             = false;
    p.diffusion_flash_attn   = false;

    sd_ctx_t* sd = new_sd_ctx(&p);
    if (!sd) {
        FSD_LOG("new_sd_ctx failed for %s", model_path);
        return nullptr;
    }
    auto* ctx = new fsd_ctx();
    ctx->sd = sd;
    return ctx;
}

FSD_API void fsd_free(fsd_ctx* ctx) {
    if (!ctx) return;
    if (ctx->sd) free_sd_ctx(ctx->sd);
    delete ctx;
}

FSD_API void fsd_request_cancel(fsd_ctx* ctx) {
    if (!ctx) return;
    ctx->cancel_requested.store(1, std::memory_order_release);
}

FSD_API const char* fsd_sd_commit(void) {
    return sd_commit();
}

FSD_API int fsd_generate(
    fsd_ctx* ctx,
    const char* prompt,
    const char* negative_prompt,
    int width,
    int height,
    int steps,
    int64_t seed,
    fsd_step_cb cb,
    void* cb_user,
    uint8_t** png_out,
    size_t* png_len_out) {

    if (!ctx || !ctx->sd || !prompt || !png_out || !png_len_out) return -1;
    *png_out = nullptr;
    *png_len_out = 0;

    ctx->cancel_requested.store(0, std::memory_order_release);

    {
        std::lock_guard<std::mutex> lk(g_active_mu);
        g_active_ctx       = ctx;
        g_active_cb        = cb;
        g_active_user      = cb_user;
        g_active_cancelled = false;
    }

    sd_img_gen_params_t p;
    sd_img_gen_params_init(&p);
    p.prompt          = prompt;
    p.negative_prompt = negative_prompt ? negative_prompt : "";
    p.width           = width;
    p.height          = height;
    p.seed            = seed;
    p.batch_count     = 1;
    p.clip_skip       = -1;          // model default
    p.sample_params.sample_steps    = steps;
    p.sample_params.sample_method   = LCM_SAMPLE_METHOD;
    p.sample_params.scheduler       = LCM_SCHEDULER;
    // LCM models are distilled to ignore CFG; 1.0 is the canonical value.
    p.sample_params.guidance.txt_cfg            = 1.0f;
    p.sample_params.guidance.img_cfg            = 1.0f;
    p.sample_params.guidance.distilled_guidance = 0.0f;

    sd_image_t* result = generate_image(ctx->sd, &p);

    bool cancelled = false;
    {
        std::lock_guard<std::mutex> lk(g_active_mu);
        cancelled = g_active_cancelled || ctx->cancel_requested.load(std::memory_order_acquire);
        g_active_ctx       = nullptr;
        g_active_cb        = nullptr;
        g_active_user      = nullptr;
        g_active_cancelled = false;
    }

    if (!result) {
        FSD_LOG("generate_image returned NULL");
        return -2;
    }

    if (cancelled) {
        // Discard the result; honour cancel.
        if (result[0].data) free(result[0].data);
        free(result);
        return -3;  // sentinel: cancelled
    }

    // Encode RGB to PNG into a heap-grown vector, then handoff via malloc
    // so the Dart side can free with our fsd_free_bytes (which calls free()).
    std::vector<uint8_t> png;
    png.reserve(64 * 1024);
    int stride = (int)result[0].width * (int)result[0].channel;
    int rc = stbi_write_png_to_func(
        png_write_to_vec, &png,
        (int)result[0].width, (int)result[0].height, (int)result[0].channel,
        result[0].data, stride);

    free(result[0].data);
    free(result);

    if (rc == 0) {
        FSD_LOG("stbi_write_png_to_func failed");
        return -4;
    }

    uint8_t* heap = (uint8_t*)malloc(png.size());
    if (!heap) return -5;
    memcpy(heap, png.data(), png.size());
    *png_out     = heap;
    *png_len_out = png.size();
    return 0;
}

FSD_API void fsd_free_bytes(uint8_t* p) {
    if (p) free(p);
}

}  // extern "C"
