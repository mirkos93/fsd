## 0.0.1 — F2.1

Initial Android scaffold.

- Wraps `leejet/stable-diffusion.cpp` (pinned commit
  `3d6064b37ef4607917f8acf2ca8c8906d5087413`) via FFI.
- Public surface: `FsdEngine` implementing the Tacita
  `ImageGenEngine` contract (`loadModel`, `unloadModel`, `generate`
  → `Stream<ImageGenProgress>`, `cancel`).
- Inference runs on a dedicated helper isolate; UI thread never
  blocks. Progress events stream via `NativeCallable.isolateLocal`
  from inside the denoising loop.
- Android: arm64-v8a only, CPU backend, `minSdk=24`, NDK r26+,
  CMake 3.22+. armeabi-v7a / x86_64 / Vulkan deferred.
- iOS scaffold present but unbuilt.
