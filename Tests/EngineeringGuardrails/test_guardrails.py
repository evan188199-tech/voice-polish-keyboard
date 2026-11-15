#!/usr/bin/env python3
import contextlib
import importlib.util
import io
import os
import pathlib
import subprocess
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[2]
def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module

gate, doctor, startup = load('verify_original_branch'), load('doctor'), load('startup_check')

class GateTests(unittest.TestCase):
    def test_project_has_no_default_development_team(self):
        spec = (ROOT / 'project.yml').read_text()
        project = (ROOT / 'VoicePolishKeyboard.xcodeproj' / 'project.pbxproj').read_text()
        self.assertNotRegex(spec, r'(?m)^\s*DEVELOPMENT_TEAM\s*:')
        self.assertNotRegex(project, r'(?m)^\s*(?:DEVELOPMENT_TEAM|DevelopmentTeam)\s*=')

    def test_exact_remote_only_and_no_writes(self):
        base = {('git','rev-parse','HEAD'):gate.SHA, ('git','status','--porcelain'):'',
                ('git','remote','get-url','origin'):gate.URL,
                ('git','ls-remote','--heads',gate.URL,gate.REF):gate.SHA + '\t' + gate.REF}
        seen = []
        def run(*args):
            seen.append(args)
            return base[args]
        with patch.object(gate, 'run', side_effect=run):
            self.assertTrue(gate.verify()[0])
            for wrong in ('', '0'*40 + '\t' + gate.REF, gate.SHA + '\trefs/heads/main'):
                base[('git','ls-remote','--heads',gate.URL,gate.REF)] = wrong
                self.assertFalse(gate.verify()[0])
            base[('git','ls-remote','--heads',gate.URL,gate.REF)] = gate.SHA + '\t' + gate.REF
            base[('git','status','--porcelain')] = ' M file'
            self.assertFalse(gate.verify()[0])
            base[('git','status','--porcelain')] = ''
            base[('git','rev-parse','HEAD')] = '0'*40
            self.assertFalse(gate.verify()[0])
            base[('git','rev-parse','HEAD')] = gate.SHA
            base[('git','remote','get-url','origin')] = 'https://github.com/other/repo.git'
            self.assertFalse(gate.verify()[0])
        self.assertTrue(all(x[1] != 'push' for x in seen))
    def test_uncertain_remote_fails(self):
        with patch.object(gate, 'run', side_effect=subprocess.TimeoutExpired('git', 1)):
            self.assertFalse(gate.verify()[0])

class DoctorTests(unittest.TestCase):
    def test_redacted_and_failures_not_misdiagnosed(self):
        secret = 'not-a-real-secret'
        with patch.dict(os.environ, {'HTTPS_PROXY':'http://user:' + secret + '@localhost:3128'}, clear=True), \
             patch.object(doctor.socket, 'create_connection', side_effect=OSError('offline ' + secret)), \
             patch.object(doctor.socket, 'getaddrinfo', side_effect=OSError('dns ' + secret)), \
             patch.object(doctor, 'command', side_effect=subprocess.CalledProcessError(1, ['gh'], stderr=secret)):
            out = io.StringIO()
            with contextlib.redirect_stdout(out): doctor.main()
            result = out.getvalue()
            for label in ('environment', 'proxy_endpoint', 'dns_direct', 'tcp_direct', 'tls_direct', 'gh_auth_status', 'github_api_read', 'git_ref_read'):
                self.assertIn(label + ':', result)
            self.assertNotIn(secret, result)
            self.assertIn('do not by themselves identify the cause', result)
    def test_proxy_unknown_vs_reachable(self):
        class Conn:
            def __enter__(self): return self
            def __exit__(self, *args): return False
        with patch.dict(os.environ, {}, clear=True): self.assertEqual(doctor.proxy_probe(), 'not_configured')
        with patch.dict(os.environ, {'HTTPS_PROXY':'http://localhost:1234'}, clear=True), patch.object(doctor.socket, 'create_connection', return_value=Conn()):
            self.assertEqual(doctor.proxy_probe(), 'reachable')

class StartupTests(unittest.TestCase):
    def test_rules_are_hashed_and_missing_tools_are_unknown(self):
        with patch.object(startup, 'git', side_effect=['branch-name', 'a' * 40, '']), \
             patch.object(startup, 'version', return_value='not_available'):
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(startup.main(), 0)
            self.assertIn('AGENTS.md sha256:', out.getvalue())
            self.assertIn('HEAD: ' + 'a' * 40, out.getvalue())
            self.assertIn('automatic rule loading by each tool is not established', out.getvalue())

if __name__ == '__main__': unittest.main()
