#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
SWIFTC="${SWIFTC:-swiftc}"
TRANSLATION_BUILD="$(mktemp -d /tmp/voice-translation.XXXXXX)"
trap 'rm -rf "$TRANSLATION_BUILD"' EXIT
"$SWIFTC" -swift-version 6 -module-cache-path "$TRANSLATION_BUILD/cache" -emit-module -emit-library \
  -module-name Combine Tests/Portable/Combine.swift -o "$TRANSLATION_BUILD/libCombine.so"
"$SWIFTC" -swift-version 6 -module-cache-path "$TRANSLATION_BUILD/cache" -I "$TRANSLATION_BUILD" -L "$TRANSLATION_BUILD" -lCombine \
  Shared/Constants.swift Shared/Core/ChineseScriptConverter.swift Shared/Core/PolishMode.swift Shared/Core/TextPolishing.swift \
  Shared/TranslationDraft.swift Shared/TranslationContentGuard.swift Shared/TranslationRequestExecutor.swift Shared/TranslationBridgeHandler.swift Shared/TranslationDeliveryGuard.swift \
  Shared/Core/TranslationService.swift Shared/Core/TranslationPreferences.swift Keyboard/TranslationViewModel.swift Keyboard/BridgeTranslationService.swift Tests/Portable/TranslationBridgeClientFixture.swift \
  Tests/TranslationLinux/main.swift -o "$TRANSLATION_BUILD/checks"
LD_LIBRARY_PATH="$TRANSLATION_BUILD${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$TRANSLATION_BUILD/checks"
