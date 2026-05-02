#!/usr/bin/env bash
# build_ios_xcframework.sh — produce ios/Frameworks/fsd.xcframework.
#
# This script MUST run on macOS with Xcode 15+ and CMake ≥ 3.22 installed
# (Homebrew: `brew install cmake`). It is the iOS counterpart of the Android
# Gradle/CMake invocation in `android/build.gradle`.
#
# Status: DRAFT. Designed but not yet executed (the original author wrote
# it from a WSL machine without a Mac in reach). Expect to find at least
# one Apple-toolchain quirk on first run; treat as a starting point, not
# a finished build.
#
# Output layout:
#   ios/Frameworks/fsd.xcframework/
#     ios-arm64/libfsd.a
#     ios-arm64_x86_64-simulator/libfsd.a
#     Info.plist
#
# Consumer side: ios/fsd.podspec declares `vendored_libraries` at that path.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BUILD="${ROOT}/build/ios"
OUT="${ROOT}/ios/Frameworks/fsd.xcframework"
SDCPP="${ROOT}/third_party/stable-diffusion.cpp"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "ERROR: this script must run on macOS (got $(uname -s))." >&2
    exit 1
fi

if ! xcrun -find xcodebuild >/dev/null 2>&1; then
    echo "ERROR: xcodebuild not found. Install Xcode + run xcode-select." >&2
    exit 1
fi

if [[ ! -d "${SDCPP}/include" ]]; then
    echo "ERROR: submodule missing at third_party/stable-diffusion.cpp." >&2
    echo "       Run: git submodule update --init --recursive" >&2
    exit 1
fi

CMAKE="${CMAKE:-cmake}"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-13.0}"

rm -rf "${BUILD}" "${OUT}"
mkdir -p "${BUILD}" "$(dirname "${OUT}")"

# Each slice configures and builds independently. We want STATIC libfsd.a
# (and a libtool merge of all transitive static deps from sd.cpp + ggml) so
# the xcframework is self-contained — the consumer's Runner.app links it
# directly and Dart resolves symbols via `DynamicLibrary.process()`.
build_slice() {
    local sdk="$1"        # iphoneos | iphonesimulator
    local archs="$2"      # "arm64" or "arm64;x86_64"
    local label="$3"      # subfolder under build/ios/

    local slice_dir="${BUILD}/${label}"
    mkdir -p "${slice_dir}"

    echo "==> Configuring ${label} (sdk=${sdk}, archs=${archs})"
    "${CMAKE}" -S "${ROOT}/src" -B "${slice_dir}" -G Xcode \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="${sdk}" \
        -DCMAKE_OSX_ARCHITECTURES="${archs}" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DFSD_IOS_STATIC=ON \
        -DSD_METAL=ON \
        -DSD_VULKAN=OFF \
        -DSD_BUILD_SHARED_LIBS=OFF \
        -DGGML_METAL=ON \
        -DGGML_METAL_EMBED_LIBRARY=ON

    echo "==> Building ${label}"
    "${CMAKE}" --build "${slice_dir}" --config Release -- -quiet

    # Find every .a produced under the slice's build dir and merge them
    # into a single libfsd_combined.a — this is what the xcframework wraps.
    local combined="${slice_dir}/libfsd_combined.a"
    local archives=()
    while IFS= read -r -d '' a; do
        archives+=("$a")
    done < <(find "${slice_dir}" -name '*.a' -not -name 'libfsd_combined.a' -print0)

    if [[ ${#archives[@]} -eq 0 ]]; then
        echo "ERROR: no .a archives produced for ${label}" >&2
        exit 1
    fi

    echo "==> Merging ${#archives[@]} archives → libfsd_combined.a"
    libtool -static -o "${combined}" "${archives[@]}"
}

build_slice "iphoneos"        "arm64"          "device"
build_slice "iphonesimulator" "arm64;x86_64"   "simulator"

echo "==> Assembling xcframework"
xcodebuild -create-xcframework \
    -library "${BUILD}/device/libfsd_combined.a"    -headers "${ROOT}/src" \
    -library "${BUILD}/simulator/libfsd_combined.a" -headers "${ROOT}/src" \
    -output "${OUT}"

echo
echo "Done: ${OUT}"
echo "Slice contents:"
find "${OUT}" -maxdepth 2 -mindepth 1 -print
