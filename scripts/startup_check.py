#!/usr/bin/env python3
"""Record local rule and checkout evidence without editing the checkout."""
import hashlib
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]

def git(*args):
    return subprocess.run(['git', '-C', str(ROOT), *args], check=True, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10).stdout.strip()

def version(name):
    executable = shutil.which(name)
    if not executable:
        return 'not_available'
    try:
        result = subprocess.run([executable, '--version'], check=True, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5).stdout
        return result.splitlines()[0][:120] if result.strip() else 'version_unavailable'
    except (OSError, subprocess.SubprocessError):
        return 'version_unavailable'

def main():
    try:
        rules = (ROOT / 'AGENTS.md').read_bytes()
        print('AGENTS.md sha256:', hashlib.sha256(rules).hexdigest())
        print('branch:', git('branch', '--show-current') or 'detached')
        print('HEAD:', git('rev-parse', 'HEAD'))
        print('working_tree:', 'modified' if git('status', '--porcelain') else 'clean')
        for tool in ('codex', 'cursor'):
            print(tool + ':', version(tool))
        print('ownership: coordinate shared files; the two proposed Cursor #2 test paths are reserved pending response')
        print('Rule bytes were read for this report; automatic rule loading by each tool is not established.')
        return 0
    except (OSError, subprocess.SubprocessError):
        print('Unable to read local rules or Git state.', file=sys.stderr)
        return 1

if __name__ == '__main__':
    sys.exit(main())
