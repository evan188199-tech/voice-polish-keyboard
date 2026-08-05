#!/usr/bin/env bash
# Build and install the self-use macOS companion + InputMethodKit input method (Apple Silicon).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEAM_ID="${DEVELOPMENT_TEAM:-45LB5X3XTW}"
CONFIG="${CONFIGURATION:-Release}"
APP_DEST="${HOME}/Applications"
IME_DEST="${HOME}/Library/Input Methods"
MODEL_NAME="sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09"
export COPYFILE_DISABLE=1
# Keep module / SPM caches off iCloud Documents (and avoid permission surprises).
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$HOME/Library/Caches/VoicePolishKeyboard/clang-module-cache}"
export SWIFT_MODULE_CACHE_PATH="${SWIFT_MODULE_CACHE_PATH:-$CLANG_MODULE_CACHE_PATH}"
mkdir -p "$CLANG_MODULE_CACHE_PATH" 2>/dev/null || true


pick_derived() {
  if [[ -n "${DERIVED_DATA_PATH:-}" ]]; then
    echo "$DERIVED_DATA_PATH"
    return
  fi
  local preferred="$HOME/Library/Developer/Xcode/DerivedData/VoicePolishKeyboard-macos"
  local fallback="/tmp/VoicePolishKeyboard-macos-dd"
  if mkdir -p "$preferred" 2>/dev/null && [[ -w "$preferred" ]]; then
    echo "$preferred"
  else
    mkdir -p "$fallback"
    echo "$fallback"
  fi
}

DERIVED="$(pick_derived)"

# Never build into the repo (iCloud Documents injects FinderInfo/fileprovider xattrs).
case "$DERIVED" in
  "$ROOT"/*)
    echo "ERROR: DERIVED_DATA_PATH resolves under the repo: $DERIVED" >&2
    echo "       That path is often iCloud-synced and breaks codesign." >&2
    echo "       Unset DERIVED_DATA_PATH or point it outside Documents." >&2
    exit 1
    ;;
esac

if [[ "$ROOT" == */Documents/* ]]; then
  echo "NOTE: project lives under Documents (often iCloud)."
  echo "      Using external DerivedData: $DERIVED"
fi

cd "$ROOT"

if [[ ! -d Vendor/Frameworks/sherpa-onnx.xcframework ]]; then
  echo "Vendor frameworks missing. Running scripts/prepare_vendor.sh ..."
  ./scripts/prepare_vendor.sh
fi

echo "==> Strip codesign detritus from vendor frameworks"
./scripts/strip_codesign_detritus.sh Vendor/Frameworks

echo "==> Generate Xcode project"
command -v xcodegen >/dev/null || { echo "xcodegen not found. brew install xcodegen" >&2; exit 1; }
xcodegen generate
python3 "$ROOT/scripts/fix_macos_xcodeproj.py"

# Skip Xcode CodeSign (iCloud/fileprovider xattrs on Documents-derived products break it).
COMMON_XCB=(
  -project VoicePolishKeyboard.xcodeproj
  -configuration "$CONFIG"
  -derivedDataPath "$DERIVED"
  -destination 'platform=macOS,arch=arm64'
  DEVELOPMENT_TEAM="$TEAM_ID"
  CODE_SIGN_STYLE=Manual
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_IDENTITY=
  ARCHS=arm64
  ONLY_ACTIVE_ARCH=YES
)

echo "==> Build MacCompanion ($CONFIG, arm64, unsigned intermediate)"
xcodebuild -scheme MacCompanion "${COMMON_XCB[@]}" build

echo "==> Build MacInputMethod ($CONFIG, arm64, unsigned intermediate)"
xcodebuild -scheme MacInputMethod "${COMMON_XCB[@]}" build

APP_SRC="$DERIVED/Build/Products/$CONFIG/VoicePolishMac.app"
[[ -d "$APP_SRC" ]] || APP_SRC="$DERIVED/Build/Products/$CONFIG/MacCompanion.app"
IME_SRC="$DERIVED/Build/Products/$CONFIG/VoicePolishInputMethod.app"
[[ -d "$IME_SRC" ]] || IME_SRC="$DERIVED/Build/Products/$CONFIG/MacInputMethod.app"

if [[ ! -d "$APP_SRC" || ! -d "$IME_SRC" ]]; then
  echo "Build products not found under $DERIVED/Build/Products/$CONFIG" >&2
  ls -la "$DERIVED/Build/Products/$CONFIG" 2>/dev/null || true
  exit 1
fi

# Stage to /tmp so codesign never sees iCloud fileprovider xattrs.
STAGE="/tmp/vpk-macos-stage-$$"
rm -rf "$STAGE"
mkdir -p "$STAGE"
echo "==> Stage products under $STAGE (no resource forks)"
ditto --norsrc --noextattr "$APP_SRC" "$STAGE/VoicePolishMac.app"
ditto --norsrc --noextattr "$IME_SRC" "$STAGE/VoicePolishInputMethod.app"
./scripts/strip_codesign_detritus.sh "$STAGE/VoicePolishMac.app" "$STAGE/VoicePolishInputMethod.app"
APP_SRC="$STAGE/VoicePolishMac.app"
IME_SRC="$STAGE/VoicePolishInputMethod.app"

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Apple Distribution|Developer ID Application/{print $2; exit}' || true)
if [[ -z "${IDENTITY:-}" ]]; then
  IDENTITY="-"
  if [[ "${ALLOW_ADHOC_SIGN:-1}" == "0" ]]; then
    echo "ERROR: no Apple Development codesigning identity found and ALLOW_ADHOC_SIGN=0." >&2
    security find-identity -v -p codesigning || true
    exit 1
  fi
  echo "WARNING: no Apple Development identity; using ad-hoc signature"
fi

sign_app() {
  local app="$1" entitlements="$2"
  if [[ -d "$app/Contents/Frameworks" ]]; then
    local fw
    for fw in "$app/Contents/Frameworks"/*.framework; do
      [[ -d "$fw" ]] || continue
      ./scripts/strip_codesign_detritus.sh "$fw"
      codesign --force --sign "$IDENTITY" --timestamp=none "$fw"
    done
  fi
  ./scripts/strip_codesign_detritus.sh "$app"
  if [[ "$IDENTITY" != "-" && -f "$entitlements" ]]; then
    codesign --force --sign "$IDENTITY" --entitlements "$entitlements" --timestamp=none "$app"
  else
    codesign --force --deep --sign "$IDENTITY" --timestamp=none "$app"
  fi
  codesign --verify --deep --strict "$app"
}

echo "==> Sign products with: $IDENTITY"
sign_app "$APP_SRC" "$ROOT/MacCompanion/MacCompanion.entitlements"
sign_app "$IME_SRC" "$ROOT/MacInputMethod/MacInputMethod.entitlements"

mkdir -p "$APP_DEST" "$IME_DEST"

echo "==> Install companion -> $APP_DEST/VoicePolishMac.app"
rm -rf "$APP_DEST/VoicePolishMac.app"
ditto --norsrc --noextattr "$APP_SRC" "$APP_DEST/VoicePolishMac.app"
./scripts/strip_codesign_detritus.sh "$APP_DEST/VoicePolishMac.app"
sign_app "$APP_DEST/VoicePolishMac.app" "$ROOT/MacCompanion/MacCompanion.entitlements"

echo "==> Install input method -> $IME_DEST/VoicePolishInputMethod.app"
killall VoicePolishInputMethod 2>/dev/null || true
rm -rf "$IME_DEST/VoicePolishInputMethod.app"
ditto --norsrc --noextattr "$IME_SRC" "$IME_DEST/VoicePolishInputMethod.app"
./scripts/strip_codesign_detritus.sh "$IME_DEST/VoicePolishInputMethod.app"
sign_app "$IME_DEST/VoicePolishInputMethod.app" "$ROOT/MacInputMethod/MacInputMethod.entitlements"

SEED_DIR="${HOME}/Library/Application Support/VoicePolishKeyboard/SenseVoiceModels/$MODEL_NAME"
VENDOR_MODEL="$ROOT/Vendor/Models/$MODEL_NAME"
if [[ -f "$VENDOR_MODEL/model.int8.onnx" && -f "$VENDOR_MODEL/tokens.txt" ]]; then
  echo "==> Seed SenseVoice model -> $SEED_DIR"
  mkdir -p "$SEED_DIR"
  cp -f "$VENDOR_MODEL/model.int8.onnx" "$VENDOR_MODEL/tokens.txt" "$SEED_DIR/"
fi

echo "==> Refresh input method services"
killall -HUP cfprefsd 2>/dev/null || true
killall VoicePolishInputMethod 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$IME_DEST/VoicePolishInputMethod.app" 2>/dev/null || true

# Keep a clean local staging copy for inspection (outside Documents preferred).
DIST_DIR="$ROOT/dist/macos"
mkdir -p "$DIST_DIR"
rm -rf "$DIST_DIR/VoicePolishMac.app" "$DIST_DIR/VoicePolishInputMethod.app"
# Prefer /tmp then copy into dist with stripped xattrs.
ditto --norsrc --noextattr "$APP_DEST/VoicePolishMac.app" "$DIST_DIR/VoicePolishMac.app" || true
ditto --norsrc --noextattr "$IME_DEST/VoicePolishInputMethod.app" "$DIST_DIR/VoicePolishInputMethod.app" || true

open "$APP_DEST/VoicePolishMac.app" || true

cat <<MSG

Installed successfully.

Next steps:
  1. System Settings → Privacy & Security → Microphone → enable VoicePolishMac / 粤英语音
  2. System Settings → Keyboard → Text Input → Edit… → + → add「粤英语音」
  3. Switch to that input source
  4. Hold Right Option, speak, release to insert

Uninstall:
  rm -rf "$APP_DEST/VoicePolishMac.app" "$IME_DEST/VoicePolishInputMethod.app"
  rm -rf "\$HOME/Library/Application Support/VoicePolishKeyboard"

MSG
