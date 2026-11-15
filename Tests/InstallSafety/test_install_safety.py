#!/usr/bin/env python3
"""Exercise device scripts with fake Xcode commands; never touches a device."""
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
DEVICE = '00008150-0123456789ABCDEF'
TEAM = 'ABCDEFGHIJ'
SHA = 'a' * 40

class InstallSafety(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.tmp = pathlib.Path(self.temp.name)
        self.log = self.tmp / 'log'
        self.env = os.environ.copy()
        self.env.update(PATH=str(self.tmp) + os.pathsep + self.env['PATH'],
                        TMPDIR=str(self.tmp), TEST_LOG=str(self.log), DEVELOPMENT_TEAM=TEAM, SOURCE_COMMIT=SHA)
        for name, body in {
            'xcodegen': 'echo xcodegen >> "$TEST_LOG"\n',
            'git': 'if [[ "$1" == rev-parse ]]; then printf "%s\n" "${FAKE_HEAD:-$SOURCE_COMMIT}"; elif [[ "$1" == status ]]; then printf "%s" "${FAKE_DIRTY:-}"; else exit 1; fi\n',
            'codesign': 'if [[ "$1" == --verify ]]; then [[ "${FAIL_SIGN:-}" != 1 ]]; else printf "Identifier=com.voicepolish.app\nTeamIdentifier=%s\n" "${SIGN_TEAM:-$DEVELOPMENT_TEAM}"; fi\n',
            'xcrun': 'printf "xcrun %s\\n" "$*" >> "$TEST_LOG"\n',
            'xcodebuild': '''printf 'xcodebuild %s\\n' "$*" >> "$TEST_LOG"
[[ "${FAIL_BUILD:-}" != 1 ]] || exit 1
while [[ $# -gt 0 ]]; do
  if [[ "$1" == -derivedDataPath ]]; then build=$2; shift 2; else shift; fi
done
app="$build/Build/Products/Debug-iphoneos/VoicePolishApp.app"
mkdir -p "$app"
python3 - "$app/Info.plist" "${BUNDLE:-com.voicepolish.app}" <<'EOF'
import plistlib, sys
with open(sys.argv[1], 'wb') as f: plistlib.dump({'CFBundleIdentifier':sys.argv[2]}, f)
EOF
''',
        }.items():
            path = self.tmp / name
            path.write_text('#!/usr/bin/env bash\nset -eu\n' + body)
            path.chmod(0o755)
    def run_script(self, script, *args, **env):
        e = dict(self.env, **env)
        return subprocess.run([str(ROOT / 'scripts' / script), *args], env=e,
                              text=True, capture_output=True)
    def calls(self):
        return self.log.read_text() if self.log.exists() else ''
    def test_explicit_selection_and_no_auto_provisioning(self):
        for args in [(), ('iphone',), (DEVICE, 'extra')]:
            self.assertNotEqual(self.run_script('install_device.sh', *args).returncode, 0)
        self.assertEqual(self.calls(), '')
        p = self.run_script('install_device.sh', DEVICE)
        self.assertEqual(p.returncode, 0, p.stderr)
        calls = self.calls()
        self.assertIn('id=' + DEVICE, calls)
        self.assertIn('install app --device ' + DEVICE, calls)
        self.assertEqual(calls.count('install app --device'), 1)
        self.assertNotIn('-allowProvisioning', calls)
        self.assertIn('DEVELOPMENT_TEAM=' + TEAM, calls)
        self.assertIn('-derivedDataPath ' + str(self.tmp), calls)
    def test_no_team_no_build(self):
        self.assertNotEqual(self.run_script('install_device.sh', DEVICE, DEVELOPMENT_TEAM='').returncode, 0)
        self.assertEqual(self.calls(), '')
    def test_source_and_signature_fail_closed(self):
        for env in ({'SOURCE_COMMIT': ''}, {'FAKE_HEAD': 'b' * 40}, {'FAKE_DIRTY': ' M file'}):
            self.assertNotEqual(self.run_script('install_device.sh', DEVICE, **env).returncode, 0)
        self.assertEqual(self.calls(), '')
        for env in ({'FAIL_SIGN': '1'}, {'SIGN_TEAM': 'ZZZZZZZZZZ'}):
            self.assertNotEqual(self.run_script('install_device.sh', DEVICE, **env).returncode, 0)
        self.assertNotIn('install app', self.calls())
    def test_build_failure_and_wrong_bundle_do_not_install(self):
        self.assertNotEqual(self.run_script('install_device.sh', DEVICE, FAIL_BUILD='1').returncode, 0)
        self.assertNotIn('install app', self.calls())
        self.assertNotEqual(self.run_script('install_device.sh', DEVICE, BUNDLE='wrong.bundle').returncode, 0)
        self.assertNotIn('install app', self.calls())
    def test_seed_requires_exact_device(self):
        source = self.tmp / 'model'; source.mkdir()
        (source / 'tokens.txt').write_text('fixture')
        (source / 'model.int8.onnx').write_text('fixture')
        self.assertNotEqual(self.run_script('seed_model_to_device.sh', MODEL_SRC=str(source)).returncode, 0)
        self.assertEqual(self.calls(), '')
        p = self.run_script('seed_model_to_device.sh', DEVICE, MODEL_SRC=str(source))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('device copy to --device ' + DEVICE, self.calls())
    def test_list_is_read_only(self):
        self.assertEqual(self.run_script('install_device.sh', 'list').returncode, 0)
        self.assertEqual(self.calls().strip(), 'xcrun devicectl list devices')

if __name__ == '__main__':
    unittest.main()
