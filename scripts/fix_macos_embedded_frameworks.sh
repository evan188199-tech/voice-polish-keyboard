#!/usr/bin/env bash
# Fix macOS app bundles after embedding SPM binary frameworks.
#
# onnxruntime is shipped as a static archive inside a shallow "framework".
# SPM still embeds it into the app; the main binary already contains Ort*
# symbols, and the shallow layout fails Xcode product validation:
#   expected Versions/Current/Resources/Info.plist
#
# This script:
# 1) Drops unused static-archive frameworks from Contents/Frameworks
# 2) Converts remaining shallow frameworks to versioned macOS layout
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <App.app|frameworks-dir> [more...]" >&2
  exit 2
fi

export COPYFILE_DISABLE=1

is_ar_archive() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  # `file` reports "current ar archive" for static libs.
  file -b "$f" 2>/dev/null | grep -qi 'ar archive'
}

convert_shallow_to_versioned() {
  local fw="$1"
  local name
  name="$(basename "$fw" .framework)"
  local binary="$fw/$name"
  local info="$fw/Info.plist"

  # Already versioned?
  if [[ -d "$fw/Versions" ]]; then
    return 0
  fi
  # Need a main binary to restructure.
  if [[ ! -e "$binary" && ! -e "$fw/$name" ]]; then
    # try executable name from Info.plist
    if [[ -f "$info" ]]; then
      local exec_name
      exec_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info" 2>/dev/null || true)"
      if [[ -n "${exec_name:-}" && -e "$fw/$exec_name" ]]; then
        binary="$fw/$exec_name"
        name="$exec_name"
      fi
    fi
  fi
  if [[ ! -e "$binary" ]]; then
    echo "warn: cannot version $fw (missing binary)" >&2
    return 0
  fi

  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/vpk-fw-XXXXXX")"
  # Move payload aside
  mkdir -p "$tmp/payload"
  # Everything except Versions goes into A
  shopt -s dotglob nullglob
  for item in "$fw"/*; do
    base="$(basename "$item")"
    [[ "$base" == "Versions" ]] && continue
    mv "$item" "$tmp/payload/"
  done
  shopt -u dotglob nullglob

  mkdir -p "$fw/Versions/A/Resources"
  # Move binary + modules/headers into Versions/A
  for item in "$tmp/payload"/*; do
    base="$(basename "$item")"
    case "$base" in
      Info.plist)
        mv "$item" "$fw/Versions/A/Resources/Info.plist"
        ;;
      Resources)
        # merge resources
        if [[ -d "$item" ]]; then
          mkdir -p "$fw/Versions/A/Resources"
          # shellcheck disable=SC2086
          mv "$item"/* "$fw/Versions/A/Resources/" 2>/dev/null || true
          rmdir "$item" 2>/dev/null || rm -rf "$item"
        fi
        ;;
      *)
        mv "$item" "$fw/Versions/A/"
        ;;
    esac
  done

  ln -sfn A "$fw/Versions/Current"
  ln -sfn "Versions/Current/$name" "$fw/$name"
  ln -sfn Versions/Current/Resources "$fw/Resources"
  if [[ -d "$fw/Versions/A/Headers" ]]; then
    ln -sfn Versions/Current/Headers "$fw/Headers"
  fi
  if [[ -d "$fw/Versions/A/Modules" ]]; then
    ln -sfn Versions/Current/Modules "$fw/Modules"
  fi

  rm -rf "$tmp"
  echo "ok: versioned $(basename "$fw")"
}

fix_framework() {
  local fw="$1"
  [[ -d "$fw" ]] || return 0
  local name
  name="$(basename "$fw" .framework)"
  local binary="$fw/$name"
  if [[ ! -e "$binary" && -e "$fw/Versions/Current/$name" ]]; then
    binary="$fw/Versions/Current/$name"
  fi

  if is_ar_archive "$binary" || is_ar_archive "$fw/Versions/Current/$name" 2>/dev/null; then
    echo "ok: removing static embed $(basename "$fw") (already linked into binary)"
    rm -rf "$fw"
    return 0
  fi

  convert_shallow_to_versioned "$fw"
}

app_load_commands() {
  local app="$1"
  local bin
  # Collect LC_LOAD_DYLIB names from main binary + nested dylibs.
  while IFS= read -r -d '' bin; do
    otool -L "$bin" 2>/dev/null || true
  done < <(find "$app/Contents/MacOS" -type f -print0 2>/dev/null || true)
}

framework_is_referenced() {
  local app="$1"
  local fwname="$2"
  local loads
  loads="$(app_load_commands "$app")"
  # Match @rpath/Name.framework or /Name.framework/
  printf '%s\n' "$loads" | grep -F "${fwname}.framework" >/dev/null 2>&1
}

fix_app_or_dir() {
  local target="$1"
  local fwdir=""
  local is_app=0
  if [[ -d "$target/Contents/Frameworks" ]]; then
    fwdir="$target/Contents/Frameworks"
    is_app=1
  elif [[ "$(basename "$target")" == "Frameworks" ]]; then
    fwdir="$target"
  elif [[ -d "$target" && "$target" == *.framework ]]; then
    fix_framework "$target"
    return 0
  elif [[ -d "$target" ]]; then
    # Treat as a frameworks container if it directly holds *.framework
    if compgen -G "$target"/*.framework >/dev/null 2>&1; then
      fwdir="$target"
    fi
  fi

  if [[ -z "$fwdir" || ! -d "$fwdir" ]]; then
    return 0
  fi

  local fw name
  for fw in "$fwdir"/*.framework; do
    [[ -d "$fw" ]] || continue
    fix_framework "$fw"
    # After static-archive removal, skip missing paths.
    [[ -d "$fw" ]] || continue
    if [[ "$is_app" -eq 1 ]]; then
      name="$(basename "$fw" .framework)"
      if ! framework_is_referenced "$target" "$name"; then
        echo "ok: removing unreferenced embed ${name}.framework"
        rm -rf "$fw"
      fi
    fi
  done
}

for arg in "$@"; do
  [[ -e "$arg" ]] || continue
  fix_app_or_dir "$arg"
done
