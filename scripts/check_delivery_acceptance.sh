#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/voice-delivery-acceptance.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
"${SWIFTC:-swiftc}" -swift-version 6 -module-cache-path "$build_dir/cache" -parse-as-library \
  Shared/Core/ChineseScriptConverter.swift \
  Shared/TranslationDraft.swift Shared/TranslationDeliveryGuard.swift \
  Shared/CorrectionReview.swift Tests/DeliveryAcceptance/main.swift \
  -o "$build_dir/checks"
"$build_dir/checks"
