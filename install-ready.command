#!/bin/zsh
# One-click install of the prebuilt new-feature macOS build.
# Double-click in Finder, or run from a normal Terminal (not Codex sandbox).
set -euo pipefail
cd "$(dirname "$0")"
export COPYFILE_DISABLE=1
export ALLOW_ADHOC_SIGN=1

echo "==> Voice Polish macOS — install prebuilt dist"
echo "Repo: $(pwd)"
echo

if [[ -x /tmp/vpk-ready-install/install.sh ]]; then
  echo "Using staged package: /tmp/vpk-ready-install"
  /tmp/vpk-ready-install/install.sh
elif [[ -x ./scripts/install_from_dist.sh && -d ./dist/macos/VoicePolishMac.app ]]; then
  echo "Using dist/macos via scripts/install_from_dist.sh"
  ./scripts/install_from_dist.sh
else
  echo "No prebuilt package found."
  echo "Run: ./rebuild-and-install-macos.command"
  exit 1
fi

echo
echo "==> Verify"
APP="$HOME/Applications/VoicePolishMac.app"
IME="$HOME/Library/Input Methods/VoicePolishInputMethod.app"
md5 -q "$APP/Contents/MacOS/VoicePolishMac" || true
codesign --verify --deep --strict "$APP" && echo "companion codesign OK"
codesign --verify --deep --strict "$IME" && echo "input method codesign OK"
echo
echo "Expected companion md5 (new features): 2e6624907ddf369aca714b069dea1715"
echo
echo "Next:"
echo "  1. Allow Microphone for VoicePolishMac"
echo "  2. System Settings → Keyboard → Text Input → Edit… → add 粤英语音"
echo "  3. Switch to that input source; hold Right Option to dictate"
echo
read -r "?Press Enter to close..."
