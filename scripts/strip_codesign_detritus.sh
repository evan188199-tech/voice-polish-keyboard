#!/usr/bin/env bash
# Remove Finder metadata / resource forks / file-provider tags that break codesign.
# Under iCloud-synced paths, xattrs can reappear; prefer building outside Documents.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <path> [path...]" >&2
  exit 2
fi

export COPYFILE_DISABLE=1

strip_one() {
  local target="$1"
  [[ -e "$target" ]] || return 0

  find "$target" \( -name '._*' -o -name '.DS_Store' \) -type f -delete 2>/dev/null || true

  if command -v dot_clean >/dev/null 2>&1; then
    dot_clean -m "$target" 2>/dev/null || true
  fi

  if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$target" 2>/dev/null || true
    while IFS= read -r -d '' path; do
      xattr -c "$path" 2>/dev/null || true
      for key in \
        com.apple.FinderInfo \
        com.apple.fileprovider.fpfs#P \
        com.apple.ResourceFork \
        com.apple.quarantine \
        com.apple.metadata:kMDItemWhereFroms \
        com.apple.lastuseddate#PS \
        com.apple.provenance \
        com.apple.macl \
        com.apple.decmpfs
      do
        xattr -d "$key" "$path" 2>/dev/null || true
      done
    done < <(find "$target" -print0 2>/dev/null || true)
  fi
}

for target in "$@"; do
  strip_one "$target"
done
