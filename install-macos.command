#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
echo "Installing Voice Polish for macOS..."
if [[ -d dist/macos/VoicePolishMac.app && -d dist/macos/VoicePolishInputMethod.app ]]; then
  echo "Using prebuilt dist/macos products"
  exec ./scripts/install_from_dist.sh "$@"
fi
exec ./scripts/install_macos.sh "$@"
