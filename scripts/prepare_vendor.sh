#!/usr/bin/env bash
# Download and assemble multi-platform sherpa-onnx + onnxruntime XCFrameworks.
# Large binaries stay gitignored under Vendor/Frameworks.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FW_DIR="$ROOT/Vendor/Frameworks"
CACHE_DIR="${VPK_VENDOR_CACHE:-/tmp/vpk-vendor}"
SHERPA_VER="v1.13.4"
ORT_VER="1.27.1"

mkdir -p "$FW_DIR" "$CACHE_DIR"
cd "$CACHE_DIR"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}
need_cmd curl
need_cmd unzip
need_cmd xcodebuild
need_cmd ditto

download() {
  local url="$1" out="$2"
  if [[ -f "$out" ]]; then
    echo "  cached: $out"
    return 0
  fi
  echo "  downloading: $url"
  curl -fL --retry 3 --retry-delay 2 -o "$out.partial" "$url"
  mv "$out.partial" "$out"
}

# --- sherpa-onnx ---
SHERPA_IOS_ZIP="sherpa-onnx-${SHERPA_VER}-ios-static.xcframework.zip"
SHERPA_MAC_ZIP="sherpa-onnx-${SHERPA_VER}-macos-static.xcframework.zip"
SHERPA_IOS_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/${SHERPA_IOS_ZIP}"
SHERPA_MAC_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/${SHERPA_MAC_ZIP}"

echo "==> sherpa-onnx ${SHERPA_VER}"
download "$SHERPA_IOS_URL" "$SHERPA_IOS_ZIP"
download "$SHERPA_MAC_URL" "$SHERPA_MAC_ZIP"

rm -rf "$CACHE_DIR/sherpa-ios" "$CACHE_DIR/sherpa-mac"
mkdir -p "$CACHE_DIR/sherpa-ios" "$CACHE_DIR/sherpa-mac"
unzip -qo "$SHERPA_IOS_ZIP" -d "$CACHE_DIR/sherpa-ios"
unzip -qo "$SHERPA_MAC_ZIP" -d "$CACHE_DIR/sherpa-mac"

find_xcfw() {
  find "$1" -maxdepth 3 -type d -name "*.xcframework" | head -1
}

SHERPA_IOS_XCFW="$(find_xcfw "$CACHE_DIR/sherpa-ios")"
SHERPA_MAC_XCFW="$(find_xcfw "$CACHE_DIR/sherpa-mac")"
if [[ -z "$SHERPA_IOS_XCFW" || -z "$SHERPA_MAC_XCFW" ]]; then
  echo "Failed to locate sherpa-onnx xcframeworks after unzip" >&2
  exit 1
fi

merge_xcframework() {
  local name="$1" ios_xcfw="$2" mac_xcfw="$3" out_path="$4"
  local work="$CACHE_DIR/merge-$name"
  rm -rf "$work" "$out_path"
  mkdir -p "$work"

  local args=()
  # Collect each platform slice as -framework / -library
  while IFS= read -r -d '' slice; do
    local base
    base="$(basename "$slice")"
    if [[ -d "$slice/$base.framework" ]]; then
      args+=(-framework "$slice/$base.framework")
    elif [[ -d "$slice" ]]; then
      # Some slices nest framework with different product name
      local fw
      fw="$(find "$slice" -maxdepth 2 -type d -name "*.framework" | head -1 || true)"
      if [[ -n "$fw" ]]; then
        args+=(-framework "$fw")
      fi
    fi
  done < <(find "$ios_xcfw" "$mac_xcfw" -mindepth 1 -maxdepth 1 -type d -print0)

  if [[ ${#args[@]} -eq 0 ]]; then
    echo "No framework slices found for $name; copying iOS and grafting macOS slice" >&2
    ditto "$ios_xcfw" "$out_path"
    local mac_slice
    mac_slice="$(find "$mac_xcfw" -mindepth 1 -maxdepth 1 -type d | head -1)"
    if [[ -n "$mac_slice" ]]; then
      ditto "$mac_slice" "$out_path/$(basename "$mac_slice")"
    fi
    return 0
  fi

  echo "  creating multi-platform $name.xcframework (${#args[@]} slices)"
  xcodebuild -create-xcframework "${args[@]}" -output "$out_path"
}

merge_xcframework "sherpa-onnx" "$SHERPA_IOS_XCFW" "$SHERPA_MAC_XCFW" "$FW_DIR/sherpa-onnx.xcframework"

# --- onnxruntime ---
echo "==> onnxruntime ${ORT_VER}"
ORT_IOS_ZIP="onnxruntime-ios-static-xcframework-${ORT_VER}.xcframework.zip"
ORT_IOS_URL="https://github.com/csukuangfj/onnxruntime-libs/releases/download/v${ORT_VER}/${ORT_IOS_ZIP}"

# Candidate macOS artifacts (official/community naming varies by release)
ORT_MAC_CANDIDATES=(
  "https://github.com/csukuangfj/onnxruntime-libs/releases/download/v${ORT_VER}/onnxruntime-osx-arm64-static_lib-${ORT_VER}.zip"
  "https://github.com/csukuangfj/onnxruntime-libs/releases/download/v${ORT_VER}/onnxruntime-osx-universal2-static_lib-${ORT_VER}.zip"
  "https://github.com/csukuangfj/onnxruntime-libs/releases/download/v${ORT_VER}/onnxruntime-macos-static-xcframework-${ORT_VER}.xcframework.zip"
  "https://github.com/microsoft/onnxruntime/releases/download/v${ORT_VER}/onnxruntime-osx-arm64-${ORT_VER}.tgz"
)

download "$ORT_IOS_URL" "$ORT_IOS_ZIP"
rm -rf "$CACHE_DIR/ort-ios"
mkdir -p "$CACHE_DIR/ort-ios"
unzip -qo "$ORT_IOS_ZIP" -d "$CACHE_DIR/ort-ios"
ORT_IOS_XCFW="$(find_xcfw "$CACHE_DIR/ort-ios")"
if [[ -z "$ORT_IOS_XCFW" ]]; then
  echo "Failed to locate onnxruntime iOS xcframework" >&2
  exit 1
fi

ORT_MAC_ARTIFACT=""
for url in "${ORT_MAC_CANDIDATES[@]}"; do
  fname="$(basename "$url")"
  if download "$url" "$fname" 2>/dev/null; then
    ORT_MAC_ARTIFACT="$fname"
    echo "  macOS onnxruntime artifact: $fname"
    break
  else
    rm -f "$fname.partial" "$fname"
  fi
done

rm -rf "$CACHE_DIR/ort-mac" "$FW_DIR/onnxruntime.xcframework"
mkdir -p "$CACHE_DIR/ort-mac"

if [[ -z "$ORT_MAC_ARTIFACT" ]]; then
  echo "WARNING: could not download macOS onnxruntime; keeping iOS-only xcframework" >&2
  ditto "$ORT_IOS_XCFW" "$FW_DIR/onnxruntime.xcframework"
else
  case "$ORT_MAC_ARTIFACT" in
    *.zip)
      unzip -qo "$ORT_MAC_ARTIFACT" -d "$CACHE_DIR/ort-mac"
      ;;
    *.tgz|*.tar.gz)
      tar -xzf "$ORT_MAC_ARTIFACT" -C "$CACHE_DIR/ort-mac"
      ;;
  esac

  MAC_XCFW="$(find_xcfw "$CACHE_DIR/ort-mac" || true)"
  if [[ -n "${MAC_XCFW:-}" ]]; then
    merge_xcframework "onnxruntime" "$ORT_IOS_XCFW" "$MAC_XCFW" "$FW_DIR/onnxruntime.xcframework"
  else
    # Build a thin macos-arm64 framework from static lib + headers if present
    LIB="$(find "$CACHE_DIR/ort-mac" -type f \( -name 'libonnxruntime*.a' -o -name 'libonnxruntime.dylib' \) | head -1 || true)"
    HDR_DIR="$(find "$CACHE_DIR/ort-mac" -type d -name 'include' | head -1 || true)"
    if [[ -n "$LIB" ]]; then
      MAC_FW="$CACHE_DIR/ort-mac-fw/onnxruntime.framework"
      rm -rf "$CACHE_DIR/ort-mac-fw"
      mkdir -p "$MAC_FW/Headers" "$MAC_FW/Modules"
      cp "$LIB" "$MAC_FW/onnxruntime"
      if [[ -n "$HDR_DIR" ]]; then
        cp -R "$HDR_DIR"/. "$MAC_FW/Headers/" 2>/dev/null || true
      fi
      # Reuse headers from iOS slice when mac package lacks them
      if [[ ! -f "$MAC_FW/Headers/onnxruntime_c_api.h" ]]; then
        IOS_HDRS="$(find "$ORT_IOS_XCFW" -type d -name Headers | head -1 || true)"
        if [[ -n "$IOS_HDRS" ]]; then
          cp -R "$IOS_HDRS"/. "$MAC_FW/Headers/"
        fi
      fi
      cat > "$MAC_FW/Modules/module.modulemap" <<'MM'
framework module onnxruntime {
  umbrella header "onnxruntime_c_api.h"
  export *
  module * { export * }
}
MM
      cat > "$MAC_FW/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>onnxruntime</string>
  <key>CFBundleIdentifier</key><string>com.microsoft.onnxruntime</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
</dict></plist>
PL
      ARGS=()
      while IFS= read -r -d '' fw; do
        ARGS+=(-framework "$fw")
      done < <(find "$ORT_IOS_XCFW" -type d -name 'onnxruntime.framework' -print0)
      ARGS+=(-framework "$MAC_FW")
      xcodebuild -create-xcframework "${ARGS[@]}" -output "$FW_DIR/onnxruntime.xcframework"
    else
      echo "WARNING: macOS onnxruntime package layout unknown; using iOS-only" >&2
      ditto "$ORT_IOS_XCFW" "$FW_DIR/onnxruntime.xcframework"
    fi
  fi
fi

# Strip metadata that breaks codesign when frameworks are embedded.
echo "==> Strip codesign detritus from assembled frameworks"
"$ROOT/scripts/strip_codesign_detritus.sh" "$FW_DIR"

echo "==> Vendor frameworks ready:"
ls -la "$FW_DIR"
find "$FW_DIR" -maxdepth 2 -type d | sort
echo "Done."
