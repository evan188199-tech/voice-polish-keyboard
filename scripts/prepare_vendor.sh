#!/usr/bin/env bash
# Download the iOS sherpa-onnx and onnxruntime XCFrameworks used by the app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FW_DIR="$ROOT/Vendor/Frameworks"
CACHE_DIR="${VPK_VENDOR_CACHE:-/tmp/vpk-vendor}"
SHERPA_VER="v1.13.4"
ORT_VER="1.27.1"

mkdir -p "$FW_DIR" "$CACHE_DIR"
cd "$CACHE_DIR"

for command in curl unzip ditto; do
  command -v "$command" >/dev/null 2>&1 || { echo "Missing required command: $command" >&2; exit 1; }
done

download() {
  local url="$1" out="$2"
  if [[ -f "$out" ]]; then
    echo "cached: $out"
    return
  fi
  curl -fL --retry 3 --retry-delay 2 -o "$out.partial" "$url"
  mv "$out.partial" "$out"
}

find_xcframework() {
  find "$1" -maxdepth 3 -type d -name "*.xcframework" | head -1
}

SHERPA_ZIP="sherpa-onnx-${SHERPA_VER}-ios-static.xcframework.zip"
SHERPA_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/${SHERPA_ZIP}"
ORT_ZIP="onnxruntime-ios-static-xcframework-${ORT_VER}.xcframework.zip"
ORT_URL="https://github.com/csukuangfj/onnxruntime-libs/releases/download/v${ORT_VER}/${ORT_ZIP}"

download "$SHERPA_URL" "$SHERPA_ZIP"
download "$ORT_URL" "$ORT_ZIP"

rm -rf "$CACHE_DIR/sherpa" "$CACHE_DIR/ort" \
  "$FW_DIR/sherpa-onnx.xcframework" "$FW_DIR/onnxruntime.xcframework"
mkdir -p "$CACHE_DIR/sherpa" "$CACHE_DIR/ort"
unzip -qo "$SHERPA_ZIP" -d "$CACHE_DIR/sherpa"
unzip -qo "$ORT_ZIP" -d "$CACHE_DIR/ort"

SHERPA_XCFW="$(find_xcframework "$CACHE_DIR/sherpa")"
ORT_XCFW="$(find_xcframework "$CACHE_DIR/ort")"
[[ -n "$SHERPA_XCFW" && -n "$ORT_XCFW" ]] || { echo "Could not locate downloaded XCFramework" >&2; exit 1; }

ditto "$SHERPA_XCFW" "$FW_DIR/sherpa-onnx.xcframework"
ditto "$ORT_XCFW" "$FW_DIR/onnxruntime.xcframework"
"$ROOT/scripts/strip_codesign_detritus.sh" "$FW_DIR"
echo "iOS vendor frameworks ready."
