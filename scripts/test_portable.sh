#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
SWIFTC="${SWIFTC:-swiftc}"
TEST_BUILD="$(mktemp -d /tmp/voice-polish-tests.XXXXXX)"
trap 'rm -rf "$TEST_BUILD"' EXIT
for module in Combine UIKit; do
  "$SWIFTC" -swift-version 6 -module-cache-path "$TEST_BUILD/cache" -emit-module -emit-library \
    -module-name "$module" "Tests/Portable/$module.swift" -o "$TEST_BUILD/lib$module.so"
done
sources=(Shared/CorrectionReview.swift Shared/PrivateReferenceIndex.swift Shared/Core/NotionPrivatePreview.swift Shared/Core/NotionSourceMetadata.swift Shared/Core/NotionHTTPTransport.swift Shared/Core/NotionImportFlow.swift Tests/Portable/PrivateIndexChecks.swift Tests/Portable/NotionPreviewChecks.swift Shared/Constants.swift Shared/VoiceKeyboardCapture.swift Shared/PlaceNameReview.swift Shared/Core/PlaceNameDictionary.swift Shared/Core/PrivateMaterialPrototype.swift Tests/Portable/MaterialChecks.swift Tests/Portable/PlaceChecks.swift Shared/Core/ClipboardHistory.swift
  Shared/Core/ChineseScriptConverter.swift Shared/Core/PolishMode.swift Shared/Core/OrderedDeliveryCursor.swift
  Shared/Core/SpokenCorrection.swift Shared/Core/FaithfulTextFormatter.swift Shared/Core/LocalTextProcessor.swift Shared/Core/TextPolishing.swift
  Tests/Portable/ContentChecks.swift
  Shared/TranslationDraft.swift Shared/TranslationDeliveryGuard.swift Shared/TranslationContentGuard.swift Shared/TranslationRequestExecutor.swift Keyboard/TranslationViewModel.swift Keyboard/BridgeTranslationService.swift Keyboard/PrivateReferenceSearchModel.swift
  Shared/Protocol/WireMessage.swift Keyboard/KeyboardBridgeClient.swift Keyboard/KeyboardViewModel.swift
  Tests/Portable/TransportStub.swift Tests/Portable/KeyboardChecks.swift)
"$SWIFTC" -swift-version 6 -D CORRECTION_TEST_FIXTURES -module-cache-path "$TEST_BUILD/cache" -I "$TEST_BUILD" -L "$TEST_BUILD" \
  -lCombine -lUIKit -parse-as-library "${sources[@]}" -o "$TEST_BUILD/checks"
LD_LIBRARY_PATH="$TEST_BUILD${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$TEST_BUILD/checks"
