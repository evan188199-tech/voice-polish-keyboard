#!/usr/bin/env python3
"""Ensure Mac targets keep Frameworks/Resources and run strip as the last build phase.

XcodeGen postCompileScripts land before Frameworks, so CodeSign still sees
iCloud fileprovider/FinderInfo xattrs on embedded frameworks. This script
reorders strip to the end of each Mac native target's buildPhases list.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PBX = ROOT / "VoicePolishKeyboard.xcodeproj" / "project.pbxproj"
TARGETS = ("MacCompanion", "MacInputMethod")
STRIP_NAME = "Strip product codesign detritus"


def main() -> int:
    if not PBX.exists():
        print(f"error: missing {PBX}", file=sys.stderr)
        return 1

    text = PBX.read_text()
    changed = False

    for target in TARGETS:
        # Match only PBXNativeTarget blocks (not PBXGroup with the same name).
        pattern = re.compile(
            rf"(\w+ /\* {re.escape(target)} \*/ = \{{\s*"
            rf"isa = PBXNativeTarget;.*?buildPhases = \()(.*?)(\);)",
            re.S,
        )
        m = pattern.search(text)
        if not m:
            print(f"warn: native target {target} not found", file=sys.stderr)
            continue

        phases_block = m.group(2)
        lines = [ln for ln in phases_block.splitlines() if ln.strip()]
        strip_lines = [ln for ln in lines if STRIP_NAME in ln]
        other_lines = [ln for ln in lines if STRIP_NAME not in ln]
        if not strip_lines:
            print(f"warn: no strip phase on {target}", file=sys.stderr)
            continue

        # Keep exactly one strip phase, last among all build phases.
        new_block = "\n" + "\n".join(other_lines + [strip_lines[-1]]) + "\n\t\t\t"
        if new_block != phases_block:
            text = text[: m.start(2)] + new_block + text[m.end(2) :]
            changed = True
            print(f"ok: moved strip phase to end for {target}")
        else:
            print(f"ok: {target} already ordered")

        # Report phase order for debugging.
        final = pattern.search(text)
        if final:
            names = re.findall(r"/\* ([^*]+) \*/", final.group(2))
            print(f"     phases: {' -> '.join(n.strip() for n in names)}")

    if changed:
        PBX.write_text(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
