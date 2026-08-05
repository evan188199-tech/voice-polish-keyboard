#!/usr/bin/env bash
# Close / disable 粤英语音 input method and restore normal typing.
# Safe for self-use: does not touch unrelated input sources.
set -euo pipefail
export COPYFILE_DISABLE=1

REPO="/Users/shoushu/Documents/github/voice-polish-keyboard"
IME_DEST="${HOME}/Library/Input Methods/VoicePolishInputMethod.app"
COMPANION="${HOME}/Applications/VoicePolishMac.app"
REMOVE_APP=0
STOP_COMPANION=0
SELECT_ABC=1

usage() {
  cat <<'USAGE'
Usage: ./scripts/disable_ime.sh [options]

Close the 粤英语音 Input Method process and switch keyboard focus away from it.

Options:
  --remove           Also delete ~/Library/Input Methods/VoicePolishInputMethod.app
  --stop-companion   Quit VoicePolishMac companion (menu-bar app)
  --keep-source      Do not try to select ABC layout
  -h, --help         Show this help

Quick recovery when "输入法卡住 / 不能切换 / 不能打字":
  ./scripts/disable_ime.sh --stop-companion
  # then use menu bar input menu or Control+Space to pick 双拼 / ABC

Full uninstall of the IME binary (companion kept):
  ./scripts/disable_ime.sh --remove

USAGE
}

for arg in "$@"; do
  case "$arg" in
    --remove) REMOVE_APP=1 ;;
    --stop-companion) STOP_COMPANION=1 ;;
    --keep-source) SELECT_ABC=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage; exit 2 ;;
  esac
done

echo "==> Stopping VoicePolishInputMethod"
killall VoicePolishInputMethod 2>/dev/null || true
# Older / staged names
killall -m 'VoicePolishInputMethod' 2>/dev/null || true

if [[ "$STOP_COMPANION" -eq 1 ]]; then
  echo "==> Stopping companion VoicePolishMac"
  killall VoicePolishMac 2>/dev/null || true
fi

# Bounce text input agents so the menu bar source list refreshes.
killall -HUP cfprefsd 2>/dev/null || true
killall TextInputMenuAgent 2>/dev/null || true

if [[ "$SELECT_ABC" -eq 1 ]]; then
  echo "==> Prefer ABC keyboard layout (fallback typing)"
  export MODULE_CACHE_PATH=/tmp/vpk-clang-tis-disable
  mkdir -p "$MODULE_CACHE_PATH"
  cat > /tmp/vpk_select_abc.swift <<'SWIFT'
import Carbon
import Foundation

func prop(_ src: TISInputSource, _ key: CFString) -> String {
  let raw = TISGetInputSourceProperty(src, key)
  guard let raw else { return "" }
  return unsafeBitCast(raw, to: CFString?.self) as String? ?? ""
}

func isEnabled(_ src: TISInputSource) -> Bool {
  let raw = TISGetInputSourceProperty(src, kTISPropertyInputSourceIsEnabled)
  guard let raw else { return false }
  let cf = unsafeBitCast(raw, to: CFBoolean?.self)
  return cf != nil && CFBooleanGetValue(cf)
}

let all = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] ?? []
var disabledIME = 0
var selectedABC = false

for src in all {
  let id = prop(src, kTISPropertyInputSourceID)
  let bundle = prop(src, kTISPropertyBundleID)
  let name = prop(src, kTISPropertyLocalizedName)
  let category = prop(src, kTISPropertyInputSourceCategory)

  let isOurs =
    id.localizedCaseInsensitiveContains("voicepolish")
    || bundle.localizedCaseInsensitiveContains("voicepolish")
    || name.contains("粤英语音")

  if isOurs {
    let err = TISDisableInputSource(src)
    print("disable ours id=\(id) name=\(name) err=\(err)")
    if err == noErr { disabledIME += 1 }
  }

  // Prefer plain US/ABC keyboard layout when available.
  if !selectedABC && category == (kTISCategoryKeyboardInputSource as String) {
    let layoutName = prop(src, kTISPropertyInputSourceID)
    if (layoutName == "com.apple.keylayout.ABC"
        || layoutName == "com.apple.keylayout.US"
        || name == "ABC"
        || name == "U.S.") && isEnabled(src) {
      let err = TISSelectInputSource(src)
      print("select layout id=\(layoutName) name=\(name) err=\(err)")
      selectedABC = (err == noErr)
    }
  }
}

if !selectedABC {
  // Last resort: select first enabled keyboard layout that is not ours.
  for src in all {
    let category = prop(src, kTISPropertyInputSourceCategory)
    let id = prop(src, kTISPropertyInputSourceID)
    let bundle = prop(src, kTISPropertyBundleID)
    if category != (kTISCategoryKeyboardInputSource as String) { continue }
    if id.localizedCaseInsensitiveContains("voicepolish") { continue }
    if bundle.localizedCaseInsensitiveContains("voicepolish") { continue }
    if !isEnabled(src) { continue }
    let err = TISSelectInputSource(src)
    print("fallback select id=\(id) err=\(err)")
    if err == noErr {
      selectedABC = true
      break
    }
  }
}

print("disabled_ime=\(disabledIME) selected_fallback=\(selectedABC)")
SWIFT
  if command -v swift >/dev/null 2>&1; then
    swift -module-cache-path "$MODULE_CACHE_PATH" /tmp/vpk_select_abc.swift || true
  else
    echo "swift not found; skip TIS select. Use menu bar input menu manually."
  fi
fi

if [[ "$REMOVE_APP" -eq 1 ]]; then
  echo "==> Removing IME app: $IME_DEST"
  rm -rf "$IME_DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -u "$IME_DEST" 2>/dev/null || true
  killall TextInputMenuAgent 2>/dev/null || true
fi

cat <<MSG

========================================
已执行关闭流程
========================================
1. VoicePolishInputMethod 进程已结束
2. 尽量切到 ABC / 其它键盘布局
$([ "$STOP_COMPANION" -eq 1 ] && echo "3. 伴随应用 VoicePolishMac 已退出" || echo "3. 伴随应用仍可在菜单栏运行（仅负责语音，不是系统输入法）")
$([ "$REMOVE_APP" -eq 1 ] && echo "4. 已删除输入法 App（系统设置里若仍显示，注销一次）" || echo "4. 输入法文件仍在 $IME_DEST （可用 --remove 删除）")

若菜单栏仍显示「粤英语音」：
  - 点菜单栏输入法图标，手动选「双拼 / ABC」
  - 或 系统设置 → 键盘 → 文本输入 → 编辑… → 去掉「粤英语音」

若只想停语音、不卸输入法：
  - 菜单栏「粤英语音」→ 停止语音会话
  - 或关闭「右 Option 语音监听」开关

重新启用：
  ./scripts/activate_ime.sh
  open "$COMPANION"

MSG
