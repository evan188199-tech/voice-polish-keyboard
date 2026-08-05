#!/usr/bin/env bash
# Activate 粤英语音 IME for self-use.
# IMPORTANT: run this in Terminal.app / iTerm (not a sandboxed agent).
set -euo pipefail
export COPYFILE_DISABLE=1

REPO="/Users/shoushu/Documents/github/voice-polish-keyboard"
IME_DEST="${HOME}/Library/Input Methods/VoicePolishInputMethod.app"
APP_DEST="${HOME}/Applications/VoicePolishMac.app"
STAGE="/tmp/vpk-ime-activate-$$"
ENTITLEMENTS="/tmp/vpk-ime-entitlements.plist"

cleanup() { rm -rf "$STAGE" 2>/dev/null || true; }
trap cleanup EXIT

echo "==> 粤英语音 IME activator"
echo "    repo: $REPO"

# Prefer freshly staged sources
SRC=""
for candidate in \
  "/tmp/vpk-macos-manual-stage/VoicePolishInputMethod.app" \
  "/tmp/vpk-ime-clean/VoicePolishInputMethod.app" \
  "/tmp/vpk-ready-install/VoicePolishInputMethod.app" \
  "$REPO/dist/macos/VoicePolishInputMethod.app"
do
  if [[ -x "$candidate/Contents/MacOS/VoicePolishInputMethod" && -f "$candidate/Contents/Info.plist" ]]; then
    SRC="$candidate"
    break
  fi
done
[[ -n "$SRC" ]] || { echo "ERROR: No staged IME binary found." >&2; exit 1; }
echo "==> Source: $SRC"
echo "==> Destination: $IME_DEST"

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Apple Development|Apple Distribution|Developer ID Application/{print $2; exit}' || true)
if [[ -z "${IDENTITY:-}" ]]; then
  echo "ERROR: No Apple Development identity found in this login session." >&2
  echo "Open Xcode → Settings → Accounts, ensure the team cert is installed," >&2
  echo "then re-run THIS script in Terminal.app." >&2
  security find-identity -v -p codesigning || true
  exit 1
fi
echo "==> Signing identity: $IDENTITY"

# Stop old instances; do NOT open TextInputMenuAgent (macOS 27 launch constraint crash).
killall VoicePolishInputMethod 2>/dev/null || true
killall TextInputMenuAgent 2>/dev/null || true

rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto --norsrc --noextattr "$SRC" "$STAGE/VoicePolishInputMethod.app"

# Always install the known-good Info.plist from the repo (Ainu-aligned).
if [[ -f "$REPO/MacInputMethod/Info.plist" ]]; then
  # Expand xcode placeholders for a concrete bundle.
  python3 - <<'PY' "$REPO/MacInputMethod/Info.plist" "$STAGE/VoicePolishInputMethod.app/Contents/Info.plist"
import sys, pathlib, re
src = pathlib.Path(sys.argv[1]).read_text()
src = src.replace("$(EXECUTABLE_NAME)", "VoicePolishInputMethod")
src = src.replace("$(PRODUCT_BUNDLE_IDENTIFIER)", "com.voicepolish.inputmethod")
pathlib.Path(sys.argv[2]).write_text(src)
print("wrote concrete Info.plist")
PY
fi

# Icon
if [[ -f "$REPO/MacInputMethod/Resources/icon.tiff" ]]; then
  mkdir -p "$STAGE/VoicePolishInputMethod.app/Contents/Resources"
  cp -f "$REPO/MacInputMethod/Resources/icon.tiff" \
    "$STAGE/VoicePolishInputMethod.app/Contents/Resources/icon.tiff"
fi
printf 'APPL????' > "$STAGE/VoicePolishInputMethod.app/Contents/PkgInfo"

# Strip detritus
if [[ -x "$REPO/scripts/strip_codesign_detritus.sh" ]]; then
  "$REPO/scripts/strip_codesign_detritus.sh" "$STAGE/VoicePolishInputMethod.app" || true
fi
xattr -cr "$STAGE/VoicePolishInputMethod.app" 2>/dev/null || true
find "$STAGE/VoicePolishInputMethod.app" \( -name '._*' -o -name '.DS_Store' \) -delete 2>/dev/null || true

cat > "$ENTITLEMENTS" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
ENT

# Sign inside-out WITHOUT hardened runtime (matches many DIY IMEs / Apple sample style).
rm -rf "$STAGE/VoicePolishInputMethod.app/Contents/_CodeSignature"
codesign --force --sign "$IDENTITY" --timestamp=none \
  "$STAGE/VoicePolishInputMethod.app/Contents/MacOS/VoicePolishInputMethod"
codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" --timestamp=none \
  "$STAGE/VoicePolishInputMethod.app"
echo "==> Stage verify:"
codesign --verify --deep --strict --verbose=2 "$STAGE/VoicePolishInputMethod.app"
codesign -dv --verbose=4 "$STAGE/VoicePolishInputMethod.app" 2>&1 | sed -n '1,25p'

# Install
mkdir -p "${HOME}/Library/Input Methods"
rm -rf "$IME_DEST"
ditto --norsrc --noextattr "$STAGE/VoicePolishInputMethod.app" "$IME_DEST"
if [[ -x "$REPO/scripts/strip_codesign_detritus.sh" ]]; then
  "$REPO/scripts/strip_codesign_detritus.sh" "$IME_DEST" || true
fi
xattr -cr "$IME_DEST" 2>/dev/null || true

# Re-sign after copy
rm -rf "$IME_DEST/Contents/_CodeSignature"
codesign --force --sign "$IDENTITY" --timestamp=none \
  "$IME_DEST/Contents/MacOS/VoicePolishInputMethod"
codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" --timestamp=none \
  "$IME_DEST"
echo "==> Installed verify:"
codesign --verify --deep --strict --verbose=2 "$IME_DEST"

# Also embed under companion if present (helps some discovery paths)
if [[ -d "$APP_DEST" ]]; then
  EMB="$APP_DEST/Contents/Library/Input Methods/VoicePolishInputMethod.app"
  mkdir -p "$APP_DEST/Contents/Library/Input Methods"
  rm -rf "$EMB"
  ditto --norsrc --noextattr "$IME_DEST" "$EMB"
  xattr -cr "$EMB" 2>/dev/null || true
  codesign --force --sign "$IDENTITY" --timestamp=none \
    "$EMB/Contents/MacOS/VoicePolishInputMethod" 2>/dev/null || true
  codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" --timestamp=none \
    "$EMB" 2>/dev/null || true
  # Re-sign companion envelope (best effort)
  codesign --force --sign "$IDENTITY" --timestamp=none "$APP_DEST" 2>/dev/null || true
  echo "==> Embedded IME into companion: $EMB"
fi

echo "==> Launch Services register"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f -R -trusted "$IME_DEST" || true
if [[ -d "$APP_DEST" ]]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f -R -trusted "$APP_DEST" || true
fi

# Bounce related daemons gently (no open TextInputMenuAgent)
killall -HUP cfprefsd 2>/dev/null || true
killall TextInputMenuAgent 2>/dev/null || true
killall TISwitcher 2>/dev/null || true
sleep 2

echo
echo "Info.plist keys:"
plutil -p "$IME_DEST/Contents/Info.plist" | grep -E 'DisplayName|Controller|Connection|TISInput|TISIntended|NSPrincipal|LSUIElement|icon|Component' || true

echo
echo "TIS probe (include disabled):"
export MODULE_CACHE_PATH=/tmp/vpk-clang-tis
mkdir -p "$MODULE_CACHE_PATH"
cat > /tmp/vpk_list_is.swift <<'SWIFT'
import Cocoa
import Carbon
let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] ?? []
var hits = 0
for src in list {
  let cfid = unsafeBitCast(TISGetInputSourceProperty(src, kTISPropertyInputSourceID), to: CFString?.self) as String? ?? ""
  let name = unsafeBitCast(TISGetInputSourceProperty(src, kTISPropertyLocalizedName), to: CFString?.self) as String? ?? ""
  let bundle = unsafeBitCast(TISGetInputSourceProperty(src, kTISPropertyBundleID), to: CFString?.self) as String? ?? ""
  let category = unsafeBitCast(TISGetInputSourceProperty(src, kTISPropertyInputSourceCategory), to: CFString?.self) as String? ?? ""
  if cfid.localizedCaseInsensitiveContains("voice")
      || name.contains("粤英")
      || bundle.localizedCaseInsensitiveContains("voicepolish") {
    print("HIT id=\(cfid) name=\(name) bundle=\(bundle) cat=\(category)")
    hits += 1
  }
}
print("total=\(list.count) hits=\(hits)")
if hits == 0 {
  print("STILL_NOT_VISIBLE")
}
SWIFT
set +e
swift -module-cache-path "$MODULE_CACHE_PATH" /tmp/vpk_list_is.swift
PROBE=$?
set -e

# Keep a clean copy for next runs
rm -rf /tmp/vpk-ime-clean
mkdir -p /tmp/vpk-ime-clean
ditto --norsrc --noextattr "$IME_DEST" /tmp/vpk-ime-clean/VoicePolishInputMethod.app

if [[ -d "$APP_DEST" ]]; then
  open "$APP_DEST" || true
fi

cat <<MSG

========================================
Done installing 粤英语音.
========================================

If TIS hits>0:
  System Settings → Keyboard → Text Input → Edit… → +
  Left: 简体中文 (also try 其他)
  Right: 粤英语音

If TIS hits=0 (common on macOS 27 beta right after install):
  1) Log out and log back in (or reboot once)
  2) Re-open the + dialog under 简体中文 / 其他 / English
  3) If still missing, re-run:
       $REPO/scripts/activate_ime.sh

Hold Right Option to dictate (companion must be running).
MSG
