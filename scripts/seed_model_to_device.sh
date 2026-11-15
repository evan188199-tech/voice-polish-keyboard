#!/usr/bin/env bash
# Copy SenseVoice model files into the app container on a connected iPhone.
# Usage:
#   ./scripts/seed_model_to_device.sh <device-id>
#   ./scripts/seed_model_to_device.sh list
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODEL_NAME="sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09"
SRC_DIR="${MODEL_SRC:-$ROOT/Vendor/Models/$MODEL_NAME}"
BUNDLE_ID="com.voicepolish.app"
DEST="Documents/SenseVoiceModels/$MODEL_NAME"

if [[ "${1:-}" == "list" && $# -eq 1 ]]; then
  exec "$ROOT/scripts/install_device.sh" list
fi

if [[ $# -ne 1 ]] || ! [[ "$1" =~ ^([0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}|[0-9A-Fa-f]{40})$ ]]; then
  echo "Pass one complete device identifier; use '$0 list' to inspect devices." >&2
  exit 2
fi
DEVICE_ID="$1"

if [[ ! -f "$SRC_DIR/model.int8.onnx" || ! -f "$SRC_DIR/tokens.txt" ]]; then
  echo "Missing model files under $SRC_DIR" >&2
  exit 1
fi

echo "Seeding SenseVoice model to device $DEVICE_ID"
echo "  source: $SRC_DIR"
echo "  dest:   appDataContainer:$BUNDLE_ID/$DEST"

set +e
OUT="$(xcrun devicectl device copy to \
  --device "$DEVICE_ID" \
  --domain-type appDataContainer \
  --domain-identifier "$BUNDLE_ID" \
  --user mobile \
  --destination "$DEST" \
  --source "$SRC_DIR/tokens.txt" \
  --source "$SRC_DIR/model.int8.onnx" \
  --timeout 600 2>&1)"
STATUS=$?
set -e
printf '%s\n' "$OUT"
if [[ $STATUS -ne 0 ]]; then
  if grep -Eqi '4016|usage assertion|CurrentlyAssertableStates|locked' <<< "$OUT"; then
    echo "Unlock iPhone, keep it awake, trust this Mac, then retry." >&2
  fi
  exit "$STATUS"
fi

echo "Seed complete. Launch app and tap 加载本地模型 / 启动语音会话."
