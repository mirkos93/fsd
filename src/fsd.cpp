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
#  include <dlfcn.h>
#  define FSD_LOG(...) __android_log_print(ANDROID_LOG_INFO, "fsd", __VA_ARGS__)
#else
#  include <cstdio>
#  ifdef FSD_HAVE_VULKAN
#    include <dlfcn.h>
#  endif
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

// ---- Vulkan runtime probe -------------------------------------------------
//
// We *never* link libvulkan into libfsd.so. On Android the loader is provided
// by the OS (api level 24+ ships /system/lib64/libvulkan.so), but plenty of
// devices ship without a Vulkan ICD or have it disabled in driver config; we
// don't want libfsd.so to fail to load on those.
//
// When SD_VULKAN was compiled in, ggml-vulkan handles its own loader
// (Vulkan-Hpp dispatch). The probe below is just for fsd_gpu_available()
// reporting.
//
// When SD_VULKAN is OFF, this always reports 0.

int probe_vulkan_devices() {
#ifdef FSD_HAVE_VULKAN
    void* libvk = dlopen("libvulkan.so", RTLD_NOW | RTLD_LOCAL);
    if (!libvk) {
        // Try the Khronos loader filename too (common on linux desktops).
        libvk = dlopen("libvulkan.so.1", RTLD_NOW | RTLD_LOCAL);
    }
    if (!libvk) {
        FSD_LOG("vulkan: libvulkan not found via dlopen");
        return 0;
    }

    using PFN_vkCreateInstance = int (*)(const void*, const void*, void**);
    using PFN_vkDestroyInstance = void (*)(void*, const void*);
    using PFN_vkEnumeratePhysicalDevices = int (*)(void*, uint32_t*, void*);

    auto vkCreateInstance =
        reinterpret_cast<PFN_vkCreateInstance>(dlsym(libvk, "vkCreateInstance"));
    auto vkDestroyInstance =
        reinterpret_cast<PFN_vkDestroyInstance>(dlsym(libvk, "vkDestroyInstance"));
    auto vkEnumeratePhysicalDevices =
        reinterpret_cast<PFN_vkEnumeratePhysicalDevices>(
            dlsym(libvk, "vkEnumeratePhysicalDevices"));
    if (!vkCreateInstance || !vkDestroyInstance || !vkEnumeratePhysicalDevices) {
        FSD_LOG("vulkan: missing required symbols in libvulkan");
        dlclose(libvk);
        return 0;
    }

    // VkInstanceCreateInfo: stype=1, sane defaults. We construct it as a raw
    // byte buffer to avoid pulling in the heavy <vulkan/vulkan.h> header here
    // — fsd.cpp doesn't depend on it.
    struct {
        int32_t  sType;
        const void* pNext;
        uint32_t flags;
        const void* pAppInfo;
        uint32_t enabledLayerCount;
        const char* const* ppEnabledLayerNames;
        uint32_t enabledExtensionCount;
        const char* const* ppEnabledExtensionNames;
    } createInfo = {};
    // VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO = 1
    createInfo.sType = 1;

    void* instance = nullptr;
    int rc = vkCreateInstance(&createInfo, nullptr, &instance);
    if (rc != 0 || !instance) {
        FSD_LOG("vulkan: vkCreateInstance rc=%d", rc);
        dlclose(libvk);
        return 0;
    }

    uint32_t count = 0;
    rc = vkEnumeratePhysicalDevices(instance, &count, nullptr);
    vkDestroyInstance(instance, nullptr);
    dlclose(libvk);

    if (rc != 0) {
        FSD_LOG("vulkan: vkEnumeratePhysicalDevices rc=%d", rc);
        return 0;
    }
    FSD_LOG("vulkan: %u device(s) available", count);
    return count > 0 ? 1 : 0;
#else
    return 0;
#endif
}

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
    // FSD-PATCH: enable flash-attention for the diffusion U-Net.
    // +20-35% sampling throughput on Tensor G3 / Snapdragon 8 Gen 2 per
    // public sd.cpp benchmarks; small constant cost on cold load.
    // The text-encoder / VAE flash_attn path stays off pending separate
    // benching — those passes are short relative to the U-Net loop.
    p.diffusion_flash_attn   = true;

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

FSD_API int fsd_gpu_available(void) {
    static int cached = -1;
    if (cached < 0) cached = probe_vulkan_devices();
    return cached;
}

// Internal: the actual generate path. Both fsd_generate and fsd_generate_v2
// land here. With params->sampler == FSD_SAMPLER_DEFAULT and lora_path == NULL
// this exactly replicates the legacy fsd_generate() path bit-for-bit.
static int fsd_generate_inner(
    fsd_ctx* ctx,
    const fsd_gen_params_t* params,
    fsd_step_cb cb,
    void* cb_user,
    uint8_t** png_out,
    size_t* png_len_out) {

    if (!ctx || !ctx->sd || !params || !params->prompt || !png_out || !png_len_out) return -1;
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
    p.prompt          = params->prompt;
    p.negative_prompt = params->negative_prompt ? params->negative_prompt : "";
    p.width           = params->width;
    p.height          = params->height;
    p.seed            = params->seed;
    p.batch_count     = 1;
    p.clip_skip       = -1;          // model default

    // Steps: 0 sentinel -> the LCM canonical 4. Keep > 0 paths untouched so
    // legacy callers (fsd_generate v1) still pass their own value through.
    int steps = params->steps > 0 ? params->steps : 4;
    p.sample_params.sample_steps    = steps;

    // FSD-PATCH: honor params->sampler. Prior to this, both enum values
    // mapped to the LCM hardcode regardless of caller intent — which made
    // a 20-step DEFAULT request waste 16 steps relative to LCM's 4-step
    // sweet spot AND produced washed-out outputs when no LCM LoRA was
    // attached. DEFAULT is the quality regime (Euler-A + Karras), LCM
    // stays on the LCM sampler+scheduler. Caller is responsible for
    // pairing LCM with steps=4 + an LCM LoRA + cfg=1.0.
    switch (params->sampler) {
    case FSD_SAMPLER_LCM:
        p.sample_params.sample_method = LCM_SAMPLE_METHOD;
        p.sample_params.scheduler     = LCM_SCHEDULER;
        break;
    case FSD_SAMPLER_DEFAULT:
    default:
        p.sample_params.sample_method = EULER_A_SAMPLE_METHOD;
        p.sample_params.scheduler     = KARRAS_SCHEDULER;
        break;
    }

    // CFG: 0 sentinel -> 1.0 (LCM canonical, also bit-for-bit matches legacy).
    float cfg = params->cfg_scale > 0.0f ? params->cfg_scale : 1.0f;
    p.sample_params.guidance.txt_cfg            = cfg;
    p.sample_params.guidance.img_cfg            = cfg;
    p.sample_params.guidance.distilled_guidance = 0.0f;

    // LoRA: pass through as a single-element sd_lora_t array. With NULL
    // lora_path we leave .loras = nullptr / .lora_count = 0 (sd_img_gen_params_init
    // zeroes it), which is the bit-for-bit-no-LoRA path.
    sd_lora_t lora_slot{};
    if (params->lora_path && params->lora_path[0] != '\0') {
        lora_slot.path        = params->lora_path;
        lora_slot.multiplier  = params->lora_scale > 0.0f ? params->lora_scale : 1.0f;
        lora_slot.is_high_noise = false;
        p.loras     = &lora_slot;
        p.lora_count = 1;
    }

    // FSD-PATCH: VAE tiling. When enabled, the VAE decode pass slices
    // the latent into overlapping tiles to bound peak RAM. Optional —
    // off by default. Caller decides per-request based on device RAM.
    if (params->vae_tiling_enabled != 0) {
        p.vae_tiling_params.enabled        = true;
        int tile = params->vae_tile_size > 0 ? params->vae_tile_size : 256;
        p.vae_tiling_params.tile_size_x    = tile;
        p.vae_tiling_params.tile_size_y    = tile;
        p.vae_tiling_params.target_overlap =
            params->vae_tile_overlap > 0.0f ? params->vae_tile_overlap : 0.25f;
    }

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

    fsd_gen_params_t params{};
    params.prompt          = prompt;
    params.negative_prompt = negative_prompt;
    params.width           = width;
    params.height          = height;
    params.steps           = steps;
    params.seed            = seed;
    params.sampler         = FSD_SAMPLER_DEFAULT;
    params.cfg_scale       = 0.0f;   // sentinel -> 1.0 in inner
    params.lora_path       = nullptr;
    params.lora_scale      = 0.0f;
    return fsd_generate_inner(ctx, &params, cb, cb_user, png_out, png_len_out);
}

FSD_API int fsd_generate_v2(
    fsd_ctx* ctx,
    const fsd_gen_params_t* params,
    fsd_step_cb cb,
    void* cb_user,
    uint8_t** png_out,
    size_t* png_len_out) {
    if (!params) return -1;
    return fsd_generate_inner(ctx, params, cb, cb_user, png_out, png_len_out);
}

FSD_API void fsd_free_bytes(uint8_t* p) {
    if (p) free(p);
}

}  // extern "C"
