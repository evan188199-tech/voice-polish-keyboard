#!/usr/bin/env bash
# Activate 粤英语音 IME (self-use). Run in Terminal.app, not sandboxed agents.
set -euo pipefail
export COPYFILE_DISABLE=1

REPO="/Users/shoushu/Documents/github/voice-polish-keyboard"
IME_DEST="${HOME}/Library/Input Methods/VoicePolishInputMethod.app"
SRC=""
for candidate in \
  "/tmp/vpk-ime-min/VoicePolishInputMethod.app" \
  "/tmp/vpk-ime-fix2/VoicePolishInputMethod.app" \
  "/tmp/vpk-ready-install/VoicePolishInputMethod.app" \
  "$REPO/dist/macos/VoicePolishInputMethod.app"
do
  if [[ -x "$candidate/Contents/MacOS/VoicePolishInputMethod" && -f "$candidate/Contents/Info.plist" ]]; then
    SRC="$candidate"
    break
  fi
done
[[ -n "$SRC" ]] || { echo "No staged IME found" >&2; exit 1; }

echo "==> Source: $SRC"
echo "==> Destination: $IME_DEST"

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Apple Development|Apple Distribution|Developer ID Application/{print $2; exit}' || true)
if [[ -z "${IDENTITY:-}" ]]; then
  echo "ERROR: No Apple Development identity found." >&2
  echo "Open Xcode → Settings → Accounts and sign in, then re-run." >&2
  exit 1
fi
echo "Signing with: $IDENTITY"

killall VoicePolishInputMethod 2>/dev/null || true
# Do NOT open TextInputMenuAgent on macOS 27 beta (Launch Constraint Violation).
# Only send HUP/kill and let launchd restart it.
killall TextInputMenuAgent 2>/dev/null || true

STAGE="/tmp/vpk-ime-activate-$$"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto --norsrc --noextattr "$SRC" "$STAGE/VoicePolishInputMethod.app"

# Prefer minimal known-good Info.plist if present in /tmp/vpk-ime-min
if [[ -f /tmp/vpk-ime-min/VoicePolishInputMethod.app/Contents/Info.plist ]]; then
  cp -f /tmp/vpk-ime-min/VoicePolishInputMethod.app/Contents/Info.plist \
    "$STAGE/VoicePolishInputMethod.app/Contents/Info.plist"
fi
if [[ -f "$REPO/MacInputMethod/Resources/icon.tiff" ]]; then
  mkdir -p "$STAGE/VoicePolishInputMethod.app/Contents/Resources"
  cp -f "$REPO/MacInputMethod/Resources/icon.tiff" \
    "$STAGE/VoicePolishInputMethod.app/Contents/Resources/icon.tiff"
fi

# Strip detritus carefully (avoid broken relative ROOT)
if [[ -x "$REPO/scripts/strip_codesign_detritus.sh" ]]; then
  "$REPO/scripts/strip_codesign_detritus.sh" "$STAGE/VoicePolishInputMethod.app" || true
fi
xattr -cr "$STAGE/VoicePolishInputMethod.app" 2>/dev/null || true
find "$STAGE/VoicePolishInputMethod.app" \( -name '._*' -o -name '.DS_Store' \) -delete 2>/dev/null || true

ENTITLEMENTS="/tmp/vpk-ime-entitlements.plist"
if [[ ! -f "$ENTITLEMENTS" ]]; then
  cat > "$ENTITLEMENTS" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
ENT
fi

# Remove old signature then re-sign with hardened runtime (more system-friendly)
rm -rf "$STAGE/VoicePolishInputMethod.app/Contents/_CodeSignature"
codesign --force --sign "$IDENTITY" \
  --options runtime \
  --entitlements "$ENTITLEMENTS" \
  --timestamp=none \
  "$STAGE/VoicePolishInputMethod.app/Contents/MacOS/VoicePolishInputMethod"
codesign --force --sign "$IDENTITY" \
  --options runtime \
  --entitlements "$ENTITLEMENTS" \
  --timestamp=none \
  "$STAGE/VoicePolishInputMethod.app"
codesign --verify --deep --strict --verbose=2 "$STAGE/VoicePolishInputMethod.app"
codesign -dv --verbose=4 "$STAGE/VoicePolishInputMethod.app" 2>&1 | sed -n '1,20p'

mkdir -p "${HOME}/Library/Input Methods"
rm -rf "$IME_DEST"
ditto --norsrc --noextattr "$STAGE/VoicePolishInputMethod.app" "$IME_DEST"
xattr -cr "$IME_DEST" 2>/dev/null || true
if [[ -x "$REPO/scripts/strip_codesign_detritus.sh" ]]; then
  "$REPO/scripts/strip_codesign_detritus.sh" "$IME_DEST" || true
fi
# re-sign after install (path change)
rm -rf "$IME_DEST/Contents/_CodeSignature"
codesign --force --sign "$IDENTITY" \
  --options runtime \
  --entitlements "$ENTITLEMENTS" \
  --timestamp=none \
  "$IME_DEST/Contents/MacOS/VoicePolishInputMethod"
codesign --force --sign "$IDENTITY" \
  --options runtime \
  --entitlements "$ENTITLEMENTS" \
  --timestamp=none \
  "$IME_DEST"
codesign --verify --deep --strict --verbose=2 "$IME_DEST"

echo "==> Register Launch Services"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f -R -trusted "$IME_DEST" || true

# Bounce input source related daemons gently
killall -HUP cfprefsd 2>/dev/null || true
killall TextInputMenuAgent 2>/dev/null || true
sleep 2

echo
echo "Info.plist summary:"
plutil -p "$IME_DEST/Contents/Info.plist" | grep -E 'TISIntended|DisplayName|Controller|Connection|NSPrincipal|icon|LSUIElement' || true

echo
echo "TIS probe:"
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
  if cfid.localizedCaseInsensitiveContains("voice") || name.contains("粤英") || bundle.localizedCaseInsensitiveContains("voicepolish") {
    print("HIT id=\(cfid) name=\(name) bundle=\(bundle) cat=\(category)")
    hits += 1
  }
}
print("total=\(list.count) hits=\(hits)")
if hits == 0 {
  print("STILL NOT VISIBLE.")
  print("On macOS 27 beta this often requires a full log out/in after a valid Development signature.")
  print("After logout: System Settings → Keyboard → Text Input → Edit… → + → 简体中文 → 粤英语音")
  print("Also try left column: 其他 / English")
}
SWIFT
swift -module-cache-path "$MODULE_CACHE_PATH" /tmp/vpk_list_is.swift || true

rm -rf "$STAGE"

if [[ -d "${HOME}/Applications/VoicePolishMac.app" ]]; then
  open "${HOME}/Applications/VoicePolishMac.app" || true
fi

cat <<MSG

If hits>0: add 粤英语音 in System Settings now.
If hits=0: log out and log back in, then re-open the + dialog under 简体中文 / 其他.

MSG
