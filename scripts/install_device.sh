#!/usr/bin/env bash
# Build VoicePolishApp for a connected physical iPhone and install it.
# Usage:
#   ./scripts/install_device.sh              # auto-pick first available iPhone
#   ./scripts/install_device.sh <device-id>  # install to a specific device
#   ./scripts/install_device.sh list         # only list available devices
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEAM_ID="${DEVELOPMENT_TEAM:-45LB5X3XTW}"
SCHEME="VoicePolishApp"
PROJECT="VoicePolishKeyboard.xcodeproj"
BUNDLE_ID="com.voicepolish.app"
cd "$ROOT"

run_with_timeout() {
  # usage: run_with_timeout SECONDS command...
  local seconds="$1"; shift
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$seconds" "$@"
  elif command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  else
    # Portable fallback: background + kill (quiet job-control noise).
    set +m
    "$@" >/tmp/vpk-timeout-cmd.out 2>/tmp/vpk-timeout-cmd.err &
    local pid=$!
    (
      sleep "$seconds"
      kill -TERM "$pid" >/dev/null 2>&1 || true
      sleep 0.2
      kill -KILL "$pid" >/dev/null 2>&1 || true
    ) >/dev/null 2>&1 &
    local watchdog=$!
    if wait "$pid" 2>/dev/null; then
      kill "$watchdog" >/dev/null 2>&1 || true
      wait "$watchdog" 2>/dev/null || true
      cat /tmp/vpk-timeout-cmd.out 2>/dev/null || true
      cat /tmp/vpk-timeout-cmd.err 1>&2 2>/dev/null || true
      return 0
    else
      local st=$?
      kill "$watchdog" >/dev/null 2>&1 || true
      wait "$watchdog" 2>/dev/null || true
      cat /tmp/vpk-timeout-cmd.out 2>/dev/null || true
      cat /tmp/vpk-timeout-cmd.err 1>&2 2>/dev/null || true
      return "$st"
    fi
  fi
}

list_from_devicectl() {
  rm -f /tmp/vpk-devices.json
  run_with_timeout 20 xcrun devicectl list devices --json-output /tmp/vpk-devices.json >/dev/null 2>&1 || true
  [[ -f /tmp/vpk-devices.json ]] || return 0
  python3 - <<'PY'
import json, sys
try:
    data = json.load(open("/tmp/vpk-devices.json"))
except Exception:
    sys.exit(0)
if isinstance(data, dict) and "error" in data:
    sys.exit(0)

candidates = []

def walk(obj):
    if isinstance(obj, dict):
        ident = obj.get("identifier") or obj.get("udid") or obj.get("coreDeviceIdentifier")
        name = str(obj.get("name") or obj.get("deviceName") or "")
        blob_parts = [name]
        for k, v in obj.items():
            if isinstance(v, (str, int, float, bool)):
                blob_parts.append(str(v))
            elif isinstance(v, dict):
                for vv in v.values():
                    if isinstance(vv, (str, int, float, bool)):
                        blob_parts.append(str(vv))
        blob = " ".join(blob_parts).lower()
        if ident and ("iphone" in blob or "ipad" in blob or "ios" in blob):
            if "simulator" not in blob and "watch" not in blob and "watchos" not in blob:
                # Prefer USB-connected paired phones over localNetwork/disconnected ones.
                wired = ("wired" in blob and "connected" in blob)
                available = wired or not any(x in blob for x in ("unavailable", "offline"))
                flag = "available" if available else "other"
                rank = 0 if wired else 1
                candidates.append((str(ident), name, flag, rank))
        for v in obj.values():
            walk(v)
    elif isinstance(obj, list):
        for v in obj:
            walk(v)

walk(data)
# Prefer wired (rank 0); keep best row per id.
best = {}
for row in candidates:
    if len(row) == 4:
        ident, name, flag, rank = row
    else:
        ident, name, flag = row
        rank = 1
    prev = best.get(ident)
    if prev is None or rank < prev[2]:
        best[ident] = (name, flag, rank)
for ident, (name, flag, rank) in sorted(best.items(), key=lambda kv: (kv[1][2], kv[0])):
    print(f"{ident}\t{name}\t{flag}")
PY
}

list_from_xcodebuild() {
  [[ -f "$PROJECT/project.pbxproj" ]] || return 0
  local dest_out
  dest_out="$(run_with_timeout 20 xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showdestinations 2>/dev/null || true)"
  DEST_OUT="$dest_out" python3 - <<'PY'
import os, re
text = os.environ.get("DEST_OUT", "")
seen = set()
for block in re.findall(r"\{[^}]*platform:iOS[^}]*\}", text):
    if "Simulator" in block or "placeholder" in block:
        continue
    mid = re.search(r"id:([0-9A-Fa-f-]+)", block)
    if not mid:
        continue
    ident = mid.group(1)
    if ident in seen:
        continue
    seen.add(ident)
    name_m = re.search(r"name:([^,}]+)", block)
    name = name_m.group(1).strip() if name_m else ""
    print(f"{ident}\t{name}\tavailable")
PY
}

list_from_xctrace() {
  local out
  out="$(run_with_timeout 10 xcrun xctrace list devices 2>/dev/null || true)"
  XCT_OUT="$out" python3 - <<'PY'
import os, re
text = os.environ.get("XCT_OUT", "")
# Examples:
# ai_home air (18.x) (00008150-000A5C540C84401C)
# iPhone Simulator ... skip
seen=set()
for line in text.splitlines():
    low=line.lower()
    if "simulator" in low or "macbook" in low or "watch" in low:
        continue
    m=re.search(r"\(([0-9A-Fa-f-]{16,})\)\s*$", line.strip())
    if not m:
        continue
    ident=m.group(1)
    if ident in seen:
        continue
    # Only keep likely iOS hardware lines.
    if not any(k in low for k in ("iphone", "ipad", "ai_home", "ipod")):
        # still allow unknown phone-like UDIDs that aren't simulators if line has version
        if not re.search(r"\(\d+\.\d+", line):
            continue
    seen.add(ident)
    name=re.sub(r"\s*\([^)]*\)\s*$", "", line.strip())
    name=re.sub(r"\s*\([^)]*\)\s*$", "", name).strip()
    print(f"{ident}\t{name}\tavailable")
PY
}

unique_devices() {
  {
    list_from_devicectl || true
    list_from_xctrace || true
    list_from_xcodebuild || true
  } | awk -F'\t' 'NF>=1 && $1!="" {
    id=$1; name=$2; flag=$3;
    if (!(id in seen)) { order[++n]=id }
    seen[id]=1
    if (name != "") names[id]=name
    if (flag=="available" || flags[id]=="") flags[id]=flag
  }
  END {
    for (i=1;i<=n;i++) {
      id=order[i];
      printf "%s\t%s\t%s\n", id, names[id], (flags[id]==""?"other":flags[id])
    }
  }'
}

print_device_list() {
  local lines
  lines="$(unique_devices || true)"
  if [[ -z "$lines" ]]; then
    echo "No physical iOS devices found."
    echo "Unlock the phone, keep it unlocked, enable Developer Mode, and trust this Mac."
    return 1
  fi
  echo "Connected iOS devices:"
  while IFS=$'\t' read -r id name flag; do
    [[ -z "$id" ]] && continue
    echo "  $id  ${name:-unknown}  (${flag:-unknown})"
  done <<< "$lines"
}

resolve_device() {
  local requested="${1:-}"
  local lines
  lines="$(unique_devices || true)"

  if [[ -z "$lines" && -z "$requested" ]]; then
    echo "No physical iOS devices found." >&2
    echo "Unlock the phone, keep it unlocked, enable Developer Mode, and trust this Mac." >&2
    exit 1
  fi

  if [[ -n "$requested" ]]; then
    if [[ -n "$lines" ]] && grep -q "^${requested}"$'\t' <<< "$lines"; then
      echo "$requested"
      return
    fi
    if [[ "$requested" =~ ^[0-9A-Fa-f-]{8,} ]]; then
      echo "Warning: device $requested not in auto-detected list; trying anyway." >&2
      echo "$requested"
      return
    fi
    echo "Requested device not found: $requested" >&2
    echo "Available:" >&2
    echo "$lines" | sed 's/^/  /' >&2
    exit 1
  fi

  local pick name
  pick="$(awk -F'\t' '$3=="available"{print $1; exit}' <<< "$lines")"
  if [[ -z "$pick" ]]; then
    pick="$(awk -F'\t' 'NR==1{print $1}' <<< "$lines")"
  fi
  name="$(awk -F'\t' -v id="$pick" '$1==id{print $2; exit}' <<< "$lines")"
  echo "Auto-selected device: ${name:-unknown} ($pick)" >&2
  echo "$pick"
}

if [[ "${1:-}" == "list" ]]; then
  # Ensure project exists for xcodebuild destination probing, but don't hard-fail.
  if [[ ! -f "$PROJECT/project.pbxproj" ]]; then
    xcodegen generate >/dev/null 2>&1 || true
  fi
  print_device_list
  exit $?
fi

echo "Generating Xcode project..."
xcodegen generate

DEVICE_ID="$(resolve_device "${1:-}")"

echo "Building for device $DEVICE_ID ..."
set +e
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "id=${DEVICE_ID}" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  build
BUILD_STATUS=$?
set -e

if [[ $BUILD_STATUS -ne 0 ]]; then
  echo "Device-specific destination failed; falling back to generic iOS device build..."
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "generic/platform=iOS" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Automatic \
    build
fi

APP=""
for candidate in "$HOME"/Library/Developer/Xcode/DerivedData/VoicePolishKeyboard-*/Build/Products/Debug-iphoneos/VoicePolishApp.app; do
  if [[ -d "$candidate" ]]; then
    APP="$candidate"
    break
  fi
done
if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "Built app not found under DerivedData." >&2
  exit 1
fi

# Re-check wired device right before install so we don't use a stale/wrong id.
LIVE_LINES="$(unique_devices || true)"
if [[ -n "$LIVE_LINES" ]]; then
  WIRED_ID="$(awk -F'\t' '$3=="available"{print $1; exit}' <<< "$LIVE_LINES")"
  if [[ -n "$WIRED_ID" && "$WIRED_ID" != "$DEVICE_ID" ]]; then
    echo "Note: switching install target to currently available device $WIRED_ID (was $DEVICE_ID)"
    DEVICE_ID="$WIRED_ID"
  fi
fi

echo "Installing $APP -> $DEVICE_ID"
set +e
INSTALL_OUT="$(xcrun devicectl device install app --device "$DEVICE_ID" "$APP" 2>&1)"
INSTALL_STATUS=$?
set -e
printf '%s\n' "$INSTALL_OUT"

if [[ $INSTALL_STATUS -ne 0 ]]; then
  echo >&2
  echo "Install failed." >&2
  if grep -Eqi '4016|usage assertion|CurrentlyAssertableStates|not paired|locked|0xE8000112|-402652910|Failed to connect to remote device' <<< "$INSTALL_OUT"; then
    echo "CoreDevice trust/lock/connection issue. On iPhone:" >&2
    echo "  1) Unlock and stay on Home Screen (not locked)" >&2
    echo "  2) Trust This Computer if prompted" >&2
    echo "  3) Settings → Privacy & Security → Developer Mode = ON" >&2
    echo "  4) Unplug/replug USB cable, then retry with explicit id:" >&2
    echo "     ./scripts/install_device.sh list" >&2
    echo "     ./scripts/install_device.sh <device-id>" >&2
  fi
  if grep -Eqi 'Unable to find a destination|not found' <<< "$INSTALL_OUT"; then
    echo "Device id may have changed. Run: ./scripts/install_device.sh list" >&2
  fi
  exit "$INSTALL_STATUS"
fi

echo
echo "Installed. Unlock the phone, then launch with:"
echo "  xcrun devicectl device process launch --device $DEVICE_ID $BUNDLE_ID"
