#!/usr/bin/env bash
# Build and install only to the explicitly specified physical device.
# Usage: DEVELOPMENT_TEAM=YOUR_TEAM_ID ./scripts/install_device.sh <device-id>
#        ./scripts/install_device.sh list
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ "${1:-}" == "list" && $# -eq 1 ]]; then
  exec xcrun devicectl list devices
fi
if [[ $# -ne 1 ]] || ! [[ "$1" =~ ^([0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}|[0-9A-Fa-f]{40})$ ]]; then
  echo "Pass one complete device identifier; use '$0 list' to inspect devices." >&2
  exit 2
fi
DEVICE_ID="$1"
TEAM_ID="${DEVELOPMENT_TEAM:-}"
if ! [[ "$TEAM_ID" =~ ^[A-Za-z0-9]{10}$ ]]; then
  echo "Set DEVELOPMENT_TEAM explicitly to your 10-character development team ID." >&2
  exit 2
fi
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/voice-polish-build.XXXXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
xcodegen generate
xcodebuild -project VoicePolishKeyboard.xcodeproj -scheme VoicePolishApp \
  -configuration Debug -destination "id=$DEVICE_ID" -derivedDataPath "$BUILD_DIR" \
  DEVELOPMENT_TEAM="$TEAM_ID" build
APP="$BUILD_DIR/Build/Products/Debug-iphoneos/VoicePolishApp.app"
# Reject a missing or redirected product and an unexpected bundle identifier.
python3 - "$BUILD_DIR" "$APP" <<'PY'
import os, plistlib, sys
root, app = map(os.path.realpath, sys.argv[1:])
try:
    if os.path.commonpath([root, app]) != root or not os.path.isdir(app):
        raise ValueError('missing or redirected app')
    info = os.path.join(app, 'Info.plist')
    if os.path.commonpath([app, os.path.realpath(info)]) != app:
        raise ValueError('redirected Info.plist')
    with open(info, 'rb') as f:
        metadata = plistlib.load(f)
    if metadata.get('CFBundleIdentifier') != 'com.voicepolish.app':
        raise ValueError('unexpected bundle identifier')
except (OSError, ValueError, plistlib.InvalidFileException) as e:
    print('Refusing to install build product:', e, file=sys.stderr)
    sys.exit(1)
PY
printf 'Installing the current build on %s\n' "$DEVICE_ID"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"
echo "Install completed. Launch the app on the selected device."
