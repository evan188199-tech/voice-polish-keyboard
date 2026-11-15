#!/usr/bin/env python3
"""Read-only acceptance gate for the one authorized original branch."""
import os
import re
import subprocess
import sys

SHA = '7e5f86b1c691f2f43a67ec6f44fc3d7f9d8da9ef'
BRANCH = 'codex/voice-first-ios-keyboard'
REPO = 'evan188199-tech/voice-polish-keyboard'
URL = 'https://github.com/' + REPO + '.git'
REF = 'refs/heads/' + BRANCH

def run(*args):
    env = dict(os.environ, GIT_TERMINAL_PROMPT='0', GH_PROMPT_DISABLED='1')
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=30, env=env).stdout.strip()

def verify():
    try:
        if run('git', 'rev-parse', 'HEAD') != SHA:
            return False, 'Local HEAD does not match the authorized commit.'
        if run('git', 'status', '--porcelain'):
            return False, 'Working tree is not clean.'
        origin = run('git', 'remote', 'get-url', 'origin')
        if origin not in (URL, URL[:-4], 'git@github.com:' + REPO + '.git', 'git@github.com:' + REPO):
            return False, 'Origin is not the authorized repository.'
        result = run('git', 'ls-remote', '--heads', URL, REF)
        if not re.fullmatch(re.escape(SHA) + r'\s+' + re.escape(REF), result):
            return False, 'Remote ref is absent, different, ambiguous, or unreadable.'
    except (OSError, subprocess.SubprocessError):
        return False, 'Unable to verify local state or remote ref.'
    return True, f'Verified {REPO} {BRANCH} at {SHA}. The remote branch is available.'

def main():
    if len(sys.argv) != 1:
        print('This gate has a fixed repository, branch and SHA.', file=sys.stderr)
        return 2
    ok, message = verify()
    print(message, file=sys.stdout if ok else sys.stderr)
    return 0 if ok else 1

if __name__ == '__main__':
    sys.exit(main())
