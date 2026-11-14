#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d /tmp/voice-wire-contract.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT
"${SWIFTC:-swiftc}" -module-cache-path "$build_dir/cache" -parse-as-library Tests/CorrectionWireContractLinux/main.swift -o "$build_dir/checks"
"$build_dir/checks"
