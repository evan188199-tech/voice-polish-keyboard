#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
SWIFTC="${SWIFTC:-swiftc}"
TEST_BUILD="$(mktemp -d /tmp/voice-clipboard-tests.XXXXXX)"
trap 'rm -rf "$TEST_BUILD"' EXIT
"$SWIFTC" -swift-version 6 -module-cache-path "$TEST_BUILD/cache" -emit-module -emit-library \
  -module-name Combine Tests/Portable/Combine.swift -o "$TEST_BUILD/libCombine.so"
"$SWIFTC" -swift-version 6 -module-cache-path "$TEST_BUILD/cache" -I "$TEST_BUILD" -L "$TEST_BUILD" -lCombine -parse-as-library \
  Shared/Core/ClipboardHistory.swift Tests/ClipboardLinux/main.swift -o "$TEST_BUILD/checks"
LD_LIBRARY_PATH="$TEST_BUILD${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$TEST_BUILD/checks"
