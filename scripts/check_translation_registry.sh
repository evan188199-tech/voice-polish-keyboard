#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d /tmp/voice-translation-registry.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT
"${SWIFTC:-swiftc}" -swift-version 6 -module-cache-path "$build_dir/cache" -parse-as-library \
  Shared/Constants.swift Shared/Core/ChineseScriptConverter.swift Shared/Core/PolishMode.swift Shared/Core/ModelConnectionDiagnostics.swift Shared/Core/TextPolishing.swift \
  Shared/TranslationDraft.swift Shared/TranslationBridgeHandler.swift Shared/TranslationContentGuard.swift Shared/TranslationRequestExecutor.swift \
  Shared/Core/TranslationService.swift Shared/Core/TranslationServiceFactory.swift Shared/Core/TranslationBoundedTransport.swift Shared/Core/TranslationServiceRegistry.swift \
  Tests/TranslationRegistryLinux/main.swift -o "$build_dir/checks"
"$build_dir/checks"
