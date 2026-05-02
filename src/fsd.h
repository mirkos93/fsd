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

#ifdef __cplusplus
}
#endif

#endif // FSD_H
