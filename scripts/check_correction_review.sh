#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d /tmp/voice-review.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT
"${SWIFTC:-swiftc}" -module-cache-path "$build_dir/cache" -parse-as-library Shared/Core/ChineseScriptConverter.swift Shared/Core/PolishMode.swift Shared/Core/SpokenCorrection.swift Shared/Core/FaithfulTextFormatter.swift Shared/CorrectionReview.swift Tests/CorrectionReviewLinux/main.swift -o "$build_dir/checks"
"$build_dir/checks"
