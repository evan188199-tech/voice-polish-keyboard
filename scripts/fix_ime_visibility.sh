#!/usr/bin/env bash
# Compatibility wrapper — full activation lives in activate_ime.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/scripts/activate_ime.sh"
