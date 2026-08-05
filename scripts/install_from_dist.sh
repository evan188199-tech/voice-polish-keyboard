#!/usr/bin/env bash
# Install prebuilt products from dist/macos (self-use).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist/macos"
APP_DEST="${HOME}/Applications"
IME_DEST="${HOME}/Library/Input Methods"
MODEL_NAME="sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09"
export COPYFILE_DISABLE=1

APP_SRC="$DIST/VoicePolishMac.app"
IME_SRC="$DIST/VoicePolishInputMethod.app"
if [[ ! -d "$APP_SRC" || ! -d "$IME_SRC" ]]; then
  echo "Missing dist products under $DIST" >&2
  echo "Expected VoicePolishMac.app and VoicePolishInputMethod.app" >&2
  exit 1
fi

STAGE="/tmp/vpk-install-stage-$$"
rm -rf "$STAGE"
mkdir -p "$STAGE"
echo "==> Stage to $STAGE (strip iCloud xattrs)"
ditto --norsrc --noextattr "$APP_SRC" "$STAGE/VoicePolishMac.app"
ditto --norsrc --noextattr "$IME_SRC" "$STAGE/VoicePolishInputMethod.app"
"$ROOT/scripts/strip_codesign_detritus.sh" "$STAGE/VoicePolishMac.app" "$STAGE/VoicePolishInputMethod.app"
# companion is statically linked; drop any leftover broken Frameworks stubs
rm -rf "$STAGE/VoicePolishMac.app/Contents/Frameworks"

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Apple Distribution|Developer ID Application/{print $2; exit}' || true)
if [[ -z "${IDENTITY:-}" ]]; then
  # Self-use default: ad-hoc when no cert is visible (common in non-Xcode shells).
  IDENTITY="-"
  if [[ "${ALLOW_ADHOC_SIGN:-1}" == "0" ]]; then
    echo "No Apple Development identity found and ALLOW_ADHOC_SIGN=0." >&2
    echo "Open Xcode → Settings → Accounts, or re-run without ALLOW_ADHOC_SIGN=0." >&2
    exit 1
  fi
  echo "WARNING: no codesign identity found; using ad-hoc signature"
fi

sign_app() {
  local app="$1" entitlements="$2"
  if [[ -d "$app/Contents/Frameworks" ]]; then
    local fw
    for fw in "$app/Contents/Frameworks"/*.framework; do
      [[ -d "$fw" ]] || continue
      "$ROOT/scripts/strip_codesign_detritus.sh" "$fw"
      codesign --force --sign "$IDENTITY" --timestamp=none "$fw"
    done
  fi
  "$ROOT/scripts/strip_codesign_detritus.sh" "$app"
  if [[ "$IDENTITY" != "-" && -f "$entitlements" ]]; then
    codesign --force --sign "$IDENTITY" --entitlements "$entitlements" --timestamp=none "$app"
  else
    codesign --force --deep --sign "$IDENTITY" --timestamp=none "$app"
  fi
  codesign --verify --deep --strict "$app"
}

echo "==> Sign with: $IDENTITY"
sign_app "$STAGE/VoicePolishMac.app" "$ROOT/MacCompanion/MacCompanion.entitlements"
sign_app "$STAGE/VoicePolishInputMethod.app" "$ROOT/MacInputMethod/MacInputMethod.entitlements"

mkdir -p "$APP_DEST" "$IME_DEST"

echo "==> Install companion -> $APP_DEST/VoicePolishMac.app"
rm -rf "$APP_DEST/VoicePolishMac.app"
ditto --norsrc --noextattr "$STAGE/VoicePolishMac.app" "$APP_DEST/VoicePolishMac.app"
"$ROOT/scripts/strip_codesign_detritus.sh" "$APP_DEST/VoicePolishMac.app"
sign_app "$APP_DEST/VoicePolishMac.app" "$ROOT/MacCompanion/MacCompanion.entitlements"

echo "==> Install input method -> $IME_DEST/VoicePolishInputMethod.app"
killall VoicePolishInputMethod 2>/dev/null || true
rm -rf "$IME_DEST/VoicePolishInputMethod.app"
ditto --norsrc --noextattr "$STAGE/VoicePolishInputMethod.app" "$IME_DEST/VoicePolishInputMethod.app"
"$ROOT/scripts/strip_codesign_detritus.sh" "$IME_DEST/VoicePolishInputMethod.app"
sign_app "$IME_DEST/VoicePolishInputMethod.app" "$ROOT/MacInputMethod/MacInputMethod.entitlements"

SEED_DIR="${HOME}/Library/Application Support/VoicePolishKeyboard/SenseVoiceModels/$MODEL_NAME"
VENDOR_MODEL="$ROOT/Vendor/Models/$MODEL_NAME"
if [[ -f "$VENDOR_MODEL/model.int8.onnx" && -f "$VENDOR_MODEL/tokens.txt" ]]; then
  echo "==> Seed model -> $SEED_DIR"
  mkdir -p "$SEED_DIR"
  cp -f "$VENDOR_MODEL/model.int8.onnx" "$VENDOR_MODEL/tokens.txt" "$SEED_DIR/"
fi

killall -HUP cfprefsd 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$IME_DEST/VoicePolishInputMethod.app" 2>/dev/null || true

open "$APP_DEST/VoicePolishMac.app" || true
rm -rf "$STAGE"

cat <<MSG

Installed.

Next:
  1. System Settings → Privacy & Security → Microphone → allow VoicePolishMac / 粤英语音
  2. System Settings → Keyboard → Text Input → Edit… → + → 粤英语音
  3. Hold Right Option, speak, release

MSG
