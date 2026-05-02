#ifndef FSD_H
#define FSD_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32) || defined(__CYGWIN__)
#  define FSD_API __declspec(dllexport)
#else
#  define FSD_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct fsd_ctx fsd_ctx;

// step_cb is invoked by the denoising loop on every step. Return 0 to request
// cancellation (best-effort: see fsd_request_cancel notes below).
typedef int (*fsd_step_cb)(int step, int total, void* user);

// Sampler family selector. Mirrors a coarse "what speed/quality regime do you
// want?" knob rather than the full sample_method_t enum from upstream — the
// fine-grained choice (Euler vs. Heun vs. DPM++) is the engine's job; the
// caller only decides between the two regimes this plugin exposes.
//
//   FSD_SAMPLER_DEFAULT — Quality regime: Euler-A sampler + Karras scheduler.
//                         For SD 1.5 base checkpoints without an LCM LoRA;
//                         caller should pass steps>=20 and cfg_scale~7.0.
//                         FSD-PATCH: prior versions of this enum mapped
//                         DEFAULT to LCM hardcoded; the C side now honors
//                         the enum value.
//   FSD_SAMPLER_LCM     — LCM sampler + LCM scheduler + cfg=1.0. Layered with
//                         an LCM LoRA via lora_path, this is the "4 step"
//                         regime: caller should pass steps=4.
typedef enum {
    FSD_SAMPLER_DEFAULT = 0,
    FSD_SAMPLER_LCM     = 1,
} fsd_sampler_t;

// Generation request. Zero-initialised fields fall back to fsd defaults:
//   - lora_path == NULL          -> no LoRA applied
//   - lora_scale == 0            -> treated as 1.0 (only when lora_path set)
//   - sampler == FSD_SAMPLER_DEFAULT
//   - cfg_scale == 0             -> treated as 1.0 (LCM canonical)
//   - steps  == 0                -> treated as 4 (LCM canonical for SD 1.5)
//   - vae_tiling_enabled == 0    -> disabled (default, matches sd.cpp)
//   - vae_tile_size == 0         -> 256 when tiling is enabled
//   - vae_tile_overlap == 0      -> 0.25 when tiling is enabled
typedef struct {
    const char*   prompt;
    const char*   negative_prompt;
    int           width;
    int           height;
    int           steps;
    int64_t       seed;
    fsd_sampler_t sampler;
    float         cfg_scale;
    const char*   lora_path;     // optional, may be NULL
    float         lora_scale;    // 0 -> 1.0 default
    // FSD-PATCH: VAE tiling. Decode the VAE in tiles to bound peak RAM
    // during the final stage; useful on RAM-tight phones (<= 6 GB) and at
    // resolutions >= 512. Has no effect on the denoising loop itself.
    // Set vae_tiling_enabled = 1 to opt in.
    int           vae_tiling_enabled;
    int           vae_tile_size;       // 0 -> 256 (sd.cpp recommended)
    float         vae_tile_overlap;    // 0 -> 0.25
} fsd_gen_params_t;

// Loads a stable-diffusion checkpoint. Returns NULL on failure.
FSD_API fsd_ctx* fsd_load(const char* model_path);

// Frees the context. Safe to call with NULL.
FSD_API void fsd_free(fsd_ctx* ctx);

// Generates one image. On success returns 0 and writes a PNG byte buffer
// allocated by malloc into *png_out (caller must call fsd_free_bytes).
// Returns non-zero on error or cancellation.
//
// LCM-friendly defaults baked in: LCM sampler, cfg_scale=1.0, no negative
// prompt weighting beyond what the caller passes, RNG = std default.
//
// NOTE: this is the legacy v1 entrypoint kept for backwards compatibility
// with consumers that don't need LoRA / sampler control. New code should call
// fsd_generate_v2.
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
    size_t* png_len_out);

// Same contract as fsd_generate but routed through fsd_gen_params_t. With
// params->lora_path == NULL and params->sampler == FSD_SAMPLER_DEFAULT, this
// is bit-for-bit equivalent to fsd_generate (same RNG, same sampler, same
// cfg). LoRA — when supplied — is loaded for the duration of this single
// generate() call and unloaded by free_sd_ctx-internal lifecycle.
FSD_API int fsd_generate_v2(
    fsd_ctx* ctx,
    const fsd_gen_params_t* params,
    fsd_step_cb cb,
    void* cb_user,
    uint8_t** png_out,
    size_t* png_len_out);

// Releases a buffer returned by fsd_generate.
FSD_API void fsd_free_bytes(uint8_t* p);

// Sets the cancel flag on ctx. The flag is read by the progress proxy after
// each denoising step. NOTE: stable-diffusion.cpp's progress callback returns
// void, so the in-flight step cannot be aborted; the next step will return
// early via the proxy and fsd_generate will return non-zero. Cancel is
// therefore "between steps", not mid-step.
FSD_API void fsd_request_cancel(fsd_ctx* ctx);

// Returns the pinned upstream stable-diffusion.cpp commit (delegates to
// sd_commit()). Useful for debugging.
FSD_API const char* fsd_sd_commit(void);

// Returns 1 if this libfsd was compiled with Vulkan compute support
// (-DSD_VULKAN=ON) AND the runtime device exposes at least one Vulkan-capable
// physical device, 0 otherwise. The runtime probe is a best-effort
// dlopen("libvulkan.so") + vkEnumeratePhysicalDevices: we never link
// libvulkan into libfsd.so directly, so a phone without a Vulkan ICD won't
// fail to load the library — we just fall back to CPU silently.
//
// On builds where SD_VULKAN was OFF this always returns 0. The CPU code path
// is unaffected and remains the default.
FSD_API int fsd_gpu_available(void);

#ifdef __cplusplus
}
#endif

#endif // FSD_H
