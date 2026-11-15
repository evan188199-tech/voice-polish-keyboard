#!/usr/bin/env python3
"""Read-only connectivity observations; never print credentials or configuration values."""
import os
import socket
import ssl
import subprocess
import urllib.parse

HOST = 'github.com'
REPO = 'evan188199-tech/voice-polish-keyboard'

def observe(fn):
    try:
        fn()
        return 'ok'
    except (OSError, ValueError, subprocess.SubprocessError):
        return 'failed_or_unavailable'

def command(*args):
    env = dict(os.environ, GIT_TERMINAL_PROMPT='0', GH_PROMPT_DISABLED='1')
    subprocess.run(args, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                   timeout=20, check=True)

def proxy_probe():
    value = next((os.environ[k] for k in ('HTTPS_PROXY', 'https_proxy', 'ALL_PROXY', 'all_proxy') if os.environ.get(k)), None)
    if not value:
        return 'not_configured'
    try:
        parsed = urllib.parse.urlsplit(value if '://' in value else 'http://' + value)
        if not parsed.hostname or not parsed.port:
            return 'unparseable'
        with socket.create_connection((parsed.hostname, parsed.port), timeout=5):
            return 'reachable'
    except (OSError, ValueError):
        return 'failed_or_unavailable'

def dns():
    socket.getaddrinfo(HOST, 443, type=socket.SOCK_STREAM)

def tcp():
    with socket.create_connection((HOST, 443), timeout=5):
        pass

def tls():
    with socket.create_connection((HOST, 443), timeout=5) as raw:
        with ssl.create_default_context().wrap_socket(raw, server_hostname=HOST):
            pass

def main():
    # Presence only; no environment values are exposed. Absence is not proof of no sandbox.
    env = 'sandbox_indicator_present' if any(os.environ.get(k) for k in ('CODEX_SANDBOX', 'SANDBOX_MODE')) else 'unknown'
    results = [('environment', env), ('proxy_endpoint', proxy_probe()),
               ('dns_direct', observe(dns)), ('tcp_direct', observe(tcp)), ('tls_direct', observe(tls)),
               ('gh_auth_status', observe(lambda: command('gh', 'auth', 'status'))),
               ('github_api_read', observe(lambda: command('gh', 'api', 'repos/' + REPO))),
               ('git_ref_read', observe(lambda: command('git', 'ls-remote', '--heads', 'https://github.com/' + REPO + '.git')))]
    for name, result in results:
        print(f'{name}: {result}')
    print('Failed checks do not by themselves identify the cause; direct checks do not test proxied TLS.')

if __name__ == '__main__':
    main()
