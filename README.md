# fsd

Flutter FFI plugin that wraps [`leejet/stable-diffusion.cpp`][sdcpp] for
on-device image generation. The public surface is a generic
`ImageGenEngine` contract plus an `FsdEngine` implementation; everything
else is plumbing.

[sdcpp]: https://github.com/leejet/stable-diffusion.cpp

## What it is

- A Dart Flutter plugin built around `dart:ffi`. No platform channels.
- Native code is `stable-diffusion.cpp` + `ggml`, compiled into a single
  `libfsd.so` (Android) / `fsd.xcframework` (iOS) via CMake.
- Inference runs on a dedicated helper isolate, so the UI thread never
  blocks on denoising.
- Progress callbacks stream out of the denoising loop via
  `NativeCallable.isolateLocal`.

## Status

| Capability | State |
|---|---|
| Android arm64-v8a (CPU) | shipped |
| Android Vulkan offload | opt-in via `fsdVulkan=true` Gradle property |
| Android armeabi-v7a | not viable (see *Why no v7a* below) |
| Android x86_64 | not built |
| iOS (Metal) | build pipeline drafted, untested without a Mac |
| SDXL | not supported |
| img2img / inpainting | not exposed |

## Pinned upstream

`third_party/stable-diffusion.cpp` is a git submodule pinned to commit
**`3d6064b37ef4607917f8acf2ca8c8906d5087413`** (`perf: speed up
tensor_to_sd_image conversion`, upstream PR #1466). Anyone cloning this
repo gets exactly that source. The same hash is exposed at runtime via
`nativeStableDiffusionCommit` (delegates to upstream `sd_commit()`).

If you bump the submodule, also update the hash in this README and
verify the example app still builds and produces valid PNGs.

## Quick start

Add the plugin as a git dependency in `pubspec.yaml` (no pub.dev release
yet):

```yaml
dependencies:
  fsd:
    git:
      url: https://github.com/mirkos93/fsd.git
      ref: <pinned-commit-sha>
```

Then run `flutter pub get`. `--recurse-submodules` is handled
automatically by the build because the submodule is fetched on first
CMake configure step (Gradle on Android, the build script on iOS).

Minimal usage:

```dart
import 'package:fsd/fsd.dart';

final engine = FsdEngine();
await engine.loadModel(modelPath: '/absolute/path/to/sd_v1.5.gguf');

final stream = engine.generate(
  request: const ImageGenRequest(
    prompt: 'a watercolour painting of a fox in a forest, soft light',
    width: 256,
    height: 256,
    steps: 4,
    sampler: FsdSampler.lcm,
    // For an LCM 4-step regime point loraPath at an LCM-distilled LoRA:
    // loraPath: '/path/to/lcm_lora_sd1.5.safetensors',
  ),
);

await for (final event in stream) {
  switch (event) {
    case ImageGenStep(:final step, :final total):
      // progress UI: step / total
    case ImageGenDone(:final pngBytes):
      // pngBytes is a Uint8List, ready to feed Image.memory(...)
    case ImageGenError(:final message):
      // surface the error
  }
}

await engine.unloadModel();
await engine.dispose();
```

Cancel a running generation with `engine.cancel()`. See *Cancel
semantics* below for the (between-step) caveat.

## Supported model formats

- **SD 1.5** weights as either `.gguf` (preferred for size) or
  `.safetensors`.
- **LoRA**: `.safetensors` and `.gguf` both work — see
  `stable-diffusion.cpp`'s `ModelLoader`. The LoRA is applied for the
  duration of one `generate()` call. The expected use is an LCM LoRA
  paired with `FsdSampler.lcm`, `steps = 4`, `cfgScale = 1.0`.
- **CLIP / VAE** weights baked into the same checkpoint as
  `stable-diffusion.cpp` expects them (i.e. a "full" SD 1.5 GGUF). No
  separate CLIP / VAE file paths are exposed.
- **Quantizations**: `Q4_0` and `Q8_0` are the realistic options on
  phones. `F16` works but is wasteful on RAM.

SDXL, SD 2.x, and Flux variants are not exposed by this plugin even
though `stable-diffusion.cpp` itself can load them — the build hasn't
been validated against them and the public API names assume SD 1.5.

## Build (Android)

Requirements:

- Flutter `>=3.41` (Dart `>=3.11`).
- Android NDK r26+ (this repo was tested with `27.0.12077973`, which
  AGP autoinstalls if it's missing).
- CMake 3.22+ (NOT 3.10 like the Flutter scaffold default — `ggml`
  needs >= 3.14 internally and `stable-diffusion.cpp` declares 3.12).
  AGP normally bundles its own; if your environment has only a broken
  system `cmake`, set `cmake.dir=/usr` (or wherever a working CMake
  install lives) in `example/android/local.properties`.

Reproduce the example app build from a clean clone:

```bash
git clone --recurse-submodules https://github.com/mirkos93/fsd.git
cd fsd
flutter pub get
cd example
flutter pub get
flutter build apk --target-platform=android-arm64 --release
# -> example/build/app/outputs/flutter-apk/app-release.apk (~40 MB)
```

The `libfsd.so` payload is ~22 MB stripped (sd.cpp + ggml + the C++
shim all statically linked, single ABI).

### Vulkan offload (opt-in)

To compile the `ggml-vulkan` backend into `libfsd.so`, pass
`-PfsdVulkan=true` (or set `fsdVulkan=true` in
`android/gradle.properties`). This:

- adds `-DSD_VULKAN=ON` to the CMake invocation,
- bumps the NDK platform to `android-28` (Vulkan 1.1 entry points
  needed by ggml-vulkan are not exported by the NDK's `libvulkan.so`
  on older platforms),
- requires `glslc` (Vulkan SDK) on the host PATH so the cross-compile
  of `vulkan-shaders-gen` can run.

The CPU code path remains the default. At runtime,
`gpuAvailable` (delegating to `fsd_gpu_available()`) reports whether
both the build had Vulkan ON and a Vulkan-capable physical device is
visible. Treat it as a UI hint rather than a switch — the engine falls
back to CPU on its own.

### Smoke-testing the example app

The example expects an absolute path to a stable-diffusion checkpoint.
The default points at the app-scoped external dir, which needs no
runtime permission:

```bash
# 1) Get an SD 1.5 checkpoint (e.g. from
#    https://huggingface.co/stable-diffusion-v1-5/stable-diffusion-v1-5)
#    + optionally an LCM LoRA distilled into a single GGUF (any
#    Q4_0 / Q8_0 build). The repo does NOT ship the model.

# 2) Push to the device after the example is installed once:
adb push sd_v1.5.gguf \
    /sdcard/Android/data/com.example.fsd_example/files/

# 3) Open the app, tap Load, then Generate.
```

## Build (iOS)

The iOS pipeline is **two-step on purpose**: there is a Mac-only build
step that produces a vendored xcframework, and a normal `pod install`
that consumes it. This keeps the per-app `pod install` fast and lets
`pod lib lint` succeed with no exotic CMake-on-CocoaPods plumbing.

**Step 1 (Mac, Xcode 15+, CMake >= 3.22 from Homebrew):**

```bash
./tool/build_ios_xcframework.sh
# -> ios/Frameworks/fsd.xcframework  (gitignored)
```

The script:
- configures CMake against the iOS toolchain twice (device arm64,
  simulator arm64+x86_64),
- builds with `SD_METAL=ON` + `GGML_METAL_EMBED_LIBRARY=ON` so Metal
  shaders are linked into the static archive,
- merges all transitive `.a` archives via `libtool -static`,
- packages the slices with `xcodebuild -create-xcframework`.

**Step 2 (any machine that consumes the plugin):**

`pod install` in the consumer app picks up `vendored_frameworks` from
`ios/fsd.podspec`. If the xcframework is missing the podspec aborts
with a clear "run the script first" message instead of silently
linking a hollow pod.

### Why this layout (and not "build everything in podspec")

- Apple's `pod install` invokes Xcode, not CMake. Trying to drive
  sd.cpp+ggml's CMake from inside a `prepare_command` works but
  makes pod install take ~5 min and re-runs on every clean checkout.
- A vendored xcframework is what production native plugins ship with.
  CI can produce it once per release; consumers never rebuild it.

### Building the xcframework on CI without owning a Mac

CircleCI, GitHub Actions, and Bitrise all expose macOS executors with
Xcode and Homebrew preinstalled. `./tool/build_ios_xcframework.sh`
runs unmodified there. Wire it into a job that uploads
`ios/Frameworks/fsd.xcframework` as a workflow artifact (or attaches
it to a GitHub release). The script is drafted but has not been
executed yet — first attempt will likely surface 1–2 toolchain quirks
to fix (Metal shader path, libtool merge order, possibly
`-fembed-bitcode` settings depending on the Xcode version).

## Why no armeabi-v7a (32-bit ARM)

`arm64-v8a` already covers ~every Android device sold since ~2015 and
is mandatory on Play Store since 2019. armeabi-v7a was excluded
deliberately because:

- An SD 1.5 checkpoint at INT8 weights ~1.5 GB resident; a 32-bit
  process gets ~2.5 GB total address space and OOMs in practice.
- ggml's fastest int8 paths use `armv8.2-a+dotprod` intrinsics that
  don't exist on v7a; the scalar fallback is roughly 2 orders of
  magnitude slower for the same work.

If you really need v7a, add `"armeabi-v7a"` to `abiFilters` in
`android/build.gradle` (and in the example's `app/build.gradle.kts`),
drop the `-march=armv8.2-a+dotprod` flag in `src/CMakeLists.txt` for
that ABI, and brace for unusable inference latency.

## Architecture

- `src/fsd.h` / `src/fsd.cpp` — the C++ shim. Seven `extern "C"`
  symbols (`fsd_load`, `fsd_free`, `fsd_generate`, `fsd_generate_v2`,
  `fsd_free_bytes`, `fsd_request_cancel`, `fsd_sd_commit`,
  `fsd_gpu_available`). Includes upstream's `stb_image_write.h` to
  encode the RGB output to PNG in the same process.
- `src/CMakeLists.txt` — disables every sd.cpp backend except CPU
  (and Vulkan, if `SD_VULKAN=ON`), builds with
  `-O3 -ffast-math -fno-finite-math-only` and `-fvisibility=hidden`,
  statically links `stable-diffusion`.
- `android/build.gradle` — pins `cmake.version = "3.22.1"`,
  `minSdk = 24`, `abiFilters = ["arm64-v8a"]`. No Kotlin/Java
  scaffolding — the plugin is pure FFI.
- `lib/fsd.dart` — `FsdEngine` implements `ImageGenEngine`. All native
  work runs on a dedicated helper isolate spawned on first use, so the
  UI thread never blocks. Progress streams back via a `ReceivePort`
  fed by `NativeCallable.isolateLocal` from inside the denoising loop.
- `example/lib/main.dart` — minimal smoke-test UI: model path field,
  Load/Unload, prompt + Generate (256x256, 4 LCM steps), live
  progress + final PNG preview.

### Cancel semantics

`FsdEngine.cancel()` calls `fsd_request_cancel(ctx)`, which sets an
atomic flag inside the C context. The flag is read by the progress
proxy after each denoising step. Caveat: upstream's progress callback
returns `void`, so an in-flight step cannot be interrupted; the
current step finishes, then `fsd_generate` returns `-3` (cancelled)
and the Dart Stream emits `ImageGenError("cancelled")`. With LCM at
4 steps and 256x256, "between steps" is a few hundred ms on a recent
phone — usually fine. If you need true mid-step abort, you'd have to
wire `ggml_backend_cpu_set_abort_callback` into the upstream code.

## Performance notes

These are very rough lower-bound numbers from `flutter run --release`
against the **Pixel emulator (x86_64 host CPU)**. Real-device numbers
should replace them once collected:

| Setup | Resolution × Steps | Per-step | Total |
|---|---|---|---|
| Pixel 8 Pro (Tensor G3, real device) | 256x256 × 4 LCM | _todo_ | _todo_ |
| Pixel 6 (Tensor G1, real device) | 256x256 × 4 LCM | _todo_ | _todo_ |
| Pixel 4a emulator AVD | 256x256 × 4 LCM | _todo_ | _todo_ |

LCM-distilled 4-step is roughly 5x faster end-to-end than vanilla SD
1.5 at 20+ steps for similar perceptual quality, at the cost of the
"plasticky" LCM look on hard prompts. Pair `FsdSampler.lcm` with an
LCM LoRA via `loraPath` for that path.

To collect numbers: run the example, generate three times in a row
(the first load amortises model mmap), copy the `[fsd]` lines from
`flutter logs`, and paste them above.

## Verifying the build

- `flutter analyze` — clean.
- Generated `.so` exports the documented `fsd_*` symbols (verify
  with `nm -D --defined-only $(find example/build -name libfsd.so) |
  grep fsd_`).
- APK size for the example: ~40 MB release, dominated by the 22 MB
  `libfsd.so`.

## Limitations

- Android arm64-v8a only. No x86_64 emulator support (excluded from
  `abiFilters`); use a real arm64 device or an arm64 emulator host.
- No SDXL / SD 2.x / Flux. The wrapper assumes SD 1.5.
- No img2img and no inpainting paths exposed today; the public API
  is text2img only.
- The progress hook is between-step (see *Cancel semantics*).
- iOS pipeline is unbuilt — first run on real Apple hardware will
  almost certainly surface toolchain quirks.

## License

MIT, matching upstream `stable-diffusion.cpp`. See
[`LICENSE`](LICENSE) for the plugin code, and
[`third_party/stable-diffusion.cpp/LICENSE`](third_party/stable-diffusion.cpp/LICENSE)
for the upstream library.
