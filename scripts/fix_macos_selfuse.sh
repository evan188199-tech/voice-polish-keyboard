#!/usr/bin/env bash
# Self-use recovery for macOS 27 beta:
# 1) Reinstall IME with Ainu-aligned Info.plist
# 2) Rebuild companion with launch-time Right Option hotkey
# 3) Open Accessibility settings for paste-mode fallback
set -euo pipefail
export COPYFILE_DISABLE=1

REPO="/Users/shoushu/Documents/github/voice-polish-keyboard"
cd "$REPO"

echo "==> Rebuild stage products"
./scripts/build_macos_manual.sh

echo "==> Activate IME"
./scripts/activate_ime.sh || true

echo "==> Restore companion to ~/Applications (Development sign)"
STAGE_APP="/tmp/vpk-macos-manual-stage/VoicePolishMac.app"
DEST_APP="${HOME}/Applications/VoicePolishMac.app"
mkdir -p "${HOME}/Applications"
rm -rf "$DEST_APP"
ditto --norsrc --noextattr "$STAGE_APP" "$DEST_APP"
./scripts/strip_codesign_detritus.sh "$DEST_APP" || true
xattr -cr "$DEST_APP" 2>/dev/null || true
# executable bits on framework binaries
find "$DEST_APP/Contents/Frameworks" -type f \( -name 'SherpaOnnxC' -o -name 'onnxruntime' \) -exec chmod a+x {} \; 2>/dev/null || true

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Apple Development|Apple Distribution|Developer ID Application/{print $2; exit}' || true)
if [[ -z "${IDENTITY:-}" ]]; then
  echo "ERROR: no codesign identity in this login session" >&2
  exit 1
fi
echo "Signing companion with: $IDENTITY"
# Sign frameworks first if present
if [[ -d "$DEST_APP/Contents/Frameworks" ]]; then
  find "$DEST_APP/Contents/Frameworks" -name '*.framework' -maxdepth 1 | while read -r fw; do
    codesign --force --sign "$IDENTITY" --timestamp=none "$fw" 2>/dev/null || true
  done
fi
codesign --force --sign "$IDENTITY" --timestamp=none "$DEST_APP/Contents/MacOS/VoicePolishMac"
codesign --force --sign "$IDENTITY" --timestamp=none "$DEST_APP"
codesign --verify --deep --strict --verbose=2 "$DEST_APP" || true

echo "==> Launch companion"
killall VoicePolishMac 2>/dev/null || true
open "$DEST_APP" || "$DEST_APP/Contents/MacOS/VoicePolishMac" &

echo "==> Open Accessibility pane (grant 粤英语音 / VoicePolishMac)"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
open "/System/Library/PreferencePanes/Security.prefPane" 2>/dev/null || true

cat <<'MSG'

========================================
自用可用路径（推荐，不依赖输入法列表）
========================================
1. 菜单栏出现「粤英语音 / 就绪」
2. 系统设置 → 隐私与安全性 → 辅助功能 → 勾选「粤英语音」
3. 系统设置 → 隐私与安全性 → 麦克风 → 勾选「粤英语音」
4. 打开 TextEdit，按住右 Option 说话，松开后文字粘贴到光标处

输入法列表仍可能 hits=0（macOS 27 beta 常见）：
- 可注销/重启后再试 System Settings → Keyboard → Text Input → +
- 左侧看 简体中文 / 其他 / English
- 即使输入法不出现，上方面板热键模式也应可用

MSG
