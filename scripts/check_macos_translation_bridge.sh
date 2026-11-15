#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_DIR="$(mktemp -d /tmp/voice-mac-bridge.XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT
swiftc -swift-version 6 -module-cache-path "$BUILD_DIR/cache" \
  Shared/Core/ChineseScriptConverter.swift Shared/TranslationDraft.swift Shared/Protocol/WireMessage.swift \
  Shared/Protocol/BridgeTransport.swift Keyboard/BridgeTranslationService.swift Tests/MacBridge/main.swift \
  -o "$BUILD_DIR/check"
"$BUILD_DIR/check"
