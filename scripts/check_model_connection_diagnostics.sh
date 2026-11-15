#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d /tmp/model-connection-check.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT
"${SWIFTC:-swiftc}" -swift-version 6 -parse-as-library -module-cache-path "$build_dir/cache" \
  Shared/Core/ModelConnectionDiagnostics.swift Tests/ModelConnectionDiagnosticsLinux/main.swift -o "$build_dir/checks"
"$build_dir/checks"
