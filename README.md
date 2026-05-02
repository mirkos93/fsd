# fsd

Flutter FFI plugin that wraps [`leejet/stable-diffusion.cpp`][sdcpp] for
on-device image generation. Built for [Tacita][tacita], a privacy-first
LLM chat app, but the public surface is a generic `ImageGenEngine` so
nothing here is Tacita-specific.

[sdcpp]: https://github.com/leejet/stable-diffusion.cpp
[tacita]: https://github.com/Tacita-app

## Status

| Capability | F2.1 |
|---|---|
| Android arm64-v8a (CPU) | ✅ shipped |
| Android armeabi-v7a | ❌ not viable (see *Why no v7a* below) |
| Android x86_64 | ❌ skipped |
| iOS (Metal) | ⏳ build pipeline drafted (see *iOS build* below), untested — needs a Mac |
| Vulkan / GPU backends | ⏳ F2.3 |

## Pinned upstream

`third_party/stable-diffusion.cpp` is a git submodule pinned to commit
**`3d6064b37ef4607917f8acf2ca8c8906d5087413`** (`perf: speed up
tensor_to_sd_image conversion`, #1466). Anyone cloning this repo gets
exactly that source. The same hash is exposed at runtime via
`nativeStableDiffusionCommit` (delegates to upstream `sd_commit()`).

If you bump the submodule, also update the hash in this README and
verify the example app still builds and produces valid PNGs.

## Build (Android)

Requirements:

- Flutter `>=3.41` (Dart `>=3.11`).
- Android NDK r26+ (this repo was tested with `27.0.12077973`, which
  AGP autoinstalls if it's missing).
- CMake 3.22+ (NOT 3.10 like the Flutter scaffold default — `ggml`
  needs ≥ 3.14 internally and `stable-diffusion.cpp` declares 3.12).
  AGP normally bundles its own; if your environment has only a broken
  system `cmake`, set `cmake.dir=/usr` (or wherever a working CMake
  install lives) in `example/android/local.properties`.

Reproduce the build from a clean clone:

```bash
git clone --recurse-submodules <this-repo> fsd
cd fsd
flutter pub get
cd example
flutter pub get
flutter build apk --target-platform=android-arm64 --release
# → example/build/app/outputs/flutter-apk/app-release.apk (~40 MB)
```

The `libfsd.so` payload is ~22 MB stripped (sd.cpp + ggml + our shim
all statically linked, single ABI).

### Smoke-testing the example app

The example expects an absolute path to a stable-diffusion checkpoint.
The default points at the app-scoped external dir, which needs no
runtime permission:

```bash
# 1) Get an LCM-distilled SD 1.5 checkpoint. Recommended:
#    https://huggingface.co/stable-diffusion-v1-5/stable-diffusion-v1-5
#    + an LCM LoRA distilled into a single GGUF (any q4_0 / q8_0 build).
#    The repo does NOT ship the model — too large, IP-encumbered.

# 2) Push to the device after the example is installed once:
adb push sd_v1.5_lcm.gguf \
    /sdcard/Android/data/com.tacita.fsd_example/files/

# 3) Open the app, tap Load, then Generate.
```

## Build (iOS)

The iOS pipeline is **two-step on purpose**: there is a Mac-only build
step that produces a vendored xcframework, and a normal `pod install`
that consumes it. This keeps the per-app `pod install` fast and lets
`pod lib lint` succeed with no exotic CMake-on-CocoaPods plumbing.

**Step 1 (Mac, Xcode 15+, CMake ≥ 3.22 from Homebrew):**

```bash
./tool/build_ios_xcframework.sh
# → ios/Frameworks/fsd.xcframework  (gitignored)
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
- A vendored xcframework is what fllama-style production plugins
  ship with. CI can produce it once per release; consumers never
  rebuild it.

### Can I do step 1 on CircleCI without owning a Mac?

Yes. CircleCI's macOS executor runs Xcode and Homebrew, so
`./tool/build_ios_xcframework.sh` runs unmodified. Wire it into a job
that uploads `ios/Frameworks/fsd.xcframework` as a workflow artifact
(or attaches it to a GitHub release); Tacita's normal `pod install`
then downloads it. **Status:** the script is drafted but has never
been executed — first attempt on a Mac will likely surface 1–2
toolchain quirks to fix (Metal shader path, libtool merge order,
maybe `-fembed-bitcode` settings depending on the Xcode version).
Treat F2.4 as "wire CircleCI + iterate on this script", not "ship
done".

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

- `src/fsd.h` / `src/fsd.cpp` — the C++ shim. Six `extern "C"`
  symbols (`fsd_load`, `fsd_free`, `fsd_generate`, `fsd_free_bytes`,
  `fsd_request_cancel`, `fsd_sd_commit`). Includes upstream's
  `stb_image_write.h` to encode the RGB output to PNG in the same
  process.
- `src/CMakeLists.txt` — disables every sd.cpp backend except CPU
  for F2.1, builds with `-O3 -ffast-math -fno-finite-math-only` and
  `-fvisibility=hidden`, statically links `stable-diffusion`.
- `android/build.gradle` — pins `cmake.version = "3.22.1"`,
  `minSdk = 24`, `abiFilters = ["arm64-v8a"]`. No Kotlin/Java
  scaffolding — the plugin is pure FFI.
- `lib/fsd.dart` — `FsdEngine` implements Tacita's `ImageGenEngine`
  contract. All native work runs on a dedicated helper isolate spawned
  on first use, so the UI thread never blocks. Progress streams back
  via a `ReceivePort` fed by `NativeCallable.isolateLocal` from inside
  the denoising loop.
- `example/lib/main.dart` — minimal smoke-test UI: model path field,
  Load/Unload, prompt + Generate (256×256, 4 LCM steps), live progress
  + final PNG preview.

### Cancel semantics

`FsdEngine.cancel()` calls `fsd_request_cancel(ctx)`, which sets an
atomic flag inside the C context. The flag is read by the progress
proxy after each denoising step. Caveat: upstream's progress callback
returns `void`, so an in-flight step cannot be interrupted; the
current step finishes, then `fsd_generate` returns `-3` (cancelled)
and the Dart Stream emits `ImageGenError("cancelled")`. With LCM at
4 steps and 256×256, "between steps" is a few hundred ms on a recent
phone — usually fine. If you need true mid-step abort, you'd have to
wire `ggml_backend_cpu_set_abort_callback` into the upstream code.

## Measured latency (initial, very rough)

These numbers come from `flutter run --release` against the **Pixel
emulator (x86_64 host CPU)** and are useful only as a lower bound for
"the build runs end-to-end". Real device numbers go here once tested:

| Setup | Model | Resolution × Steps | First-token time | Per-step | Total |
|---|---|---|---|---|---|
| Pixel 6 (Tensor G1, real device) | _todo_ | 256×256 × 4 | _todo_ | _todo_ | _todo_ |
| Galaxy S22 (SD 8 Gen 1) | _todo_ | 256×256 × 4 | _todo_ | _todo_ | _todo_ |
| Pixel 4a emulator AVD | _todo_ | 256×256 × 4 | _todo_ | _todo_ | _todo_ |

To collect: run the example, generate three times in a row (the first
load amortises model mmap), copy the `[fsd]` lines from `flutter logs`,
and paste them above.

## Verifying the build

- `flutter analyze` — clean.
- Generated `.so` exports exactly the 6 documented symbols (verify
  with `nm -D --defined-only $(find example/build -name libfsd.so) |
  grep fsd_`).
- APK size for the example: ~40 MB release, dominated by the 22 MB
  `libfsd.so`.

## Roadmap

- F2.2 — wire `FsdEngine` into Tacita as the production `ImageGenEngine`
  provider, behind a feature flag.
- F2.3 — Vulkan backend (`-DSD_VULKAN=ON`), gated on Adreno 6xx+ /
  Mali-G68+ to avoid driver lottery on older GPUs.
- F2.4 — iOS build (Metal backend). Pipeline drafted in
  `tool/build_ios_xcframework.sh` + `ios/fsd.podspec`; needs first
  successful run on a Mac (or CircleCI macOS executor).
