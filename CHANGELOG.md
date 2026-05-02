## 0.0.1

Initial public release.

- Wraps `leejet/stable-diffusion.cpp` (pinned commit
  `3d6064b37ef4607917f8acf2ca8c8906d5087413`) via FFI.
- Public surface: `FsdEngine` implementing the `ImageGenEngine`
  contract (`loadModel`, `unloadModel`, `generate`
  -> `Stream<ImageGenProgress>`, `cancel`).
- Inference runs on a dedicated helper isolate; UI thread never
  blocks. Progress events stream via `NativeCallable.isolateLocal`
  from inside the denoising loop.
- Android: arm64-v8a only, CPU backend by default, `minSdk=24`,
  NDK r26+, CMake 3.22+. armeabi-v7a / x86_64 not built.
- Optional Vulkan offload on Android via `-PfsdVulkan=true` Gradle
  property; runtime probe via `gpuAvailable` /
  `fsd_gpu_available()`. CPU stays the default.
- v2 generation API (`fsd_generate_v2` / `ImageGenRequest`) with
  structured params: sampler, cfg scale, LoRA path, LoRA scale.
  Bit-for-bit identical to the legacy `fsd_generate` when no LoRA
  / sampler overrides are set.
- iOS scaffold present (Metal backend via vendored xcframework);
  build script drafted, untested without a Mac.
