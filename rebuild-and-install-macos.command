#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
echo "==> Rebuild + install Voice Polish for macOS (new features)"
export COPYFILE_DISABLE=1
export ALLOW_ADHOC_SIGN=1
export DERIVED_DATA_PATH="$HOME/Library/Developer/Xcode/DerivedData/VoicePolishKeyboard-macos"
export CLANG_MODULE_CACHE_PATH="$HOME/Library/Caches/VoicePolishKeyboard/clang-module-cache"
export SWIFT_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$DERIVED_DATA_PATH" "$CLANG_MODULE_CACHE_PATH"

# Prefer full xcodebuild path for SwiftUI macros; fall back to manual if needed.
if ./scripts/install_macos.sh; then
  echo "install_macos.sh succeeded"
else
  echo "install_macos.sh failed; trying manual swiftc build + install_from_dist"
  ./scripts/build_macos_manual.sh
  ./scripts/install_from_dist.sh
fi

echo
echo "Done. Check menu bar for 粤英语音 companion."
read -r "?Press Enter to close..."
