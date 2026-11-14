#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d /tmp/voice-delivery-contract.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT
"${SWIFTC:-swiftc}" -module-cache-path "$build_dir/cache" -parse-as-library Shared/Protocol/WireMessage.swift Tests/CorrectionDeliveryContractLinux/main.swift -o "$build_dir/checks"
"$build_dir/checks"
