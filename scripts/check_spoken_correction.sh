#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d /tmp/voice-correction.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT
"${SWIFTC:-swiftc}" -module-cache-path "$build_dir/cache" -parse-as-library Shared/Core/ChineseScriptConverter.swift Shared/Core/PolishMode.swift Shared/Core/SpokenCorrection.swift Shared/Core/FaithfulTextFormatter.swift Tests/SpokenCorrectionLinux/main.swift -o "$build_dir/checks"
"$build_dir/checks"
