#!/usr/bin/env python3
"""Offline workflow tests. Requires PyYAML; never calls real gh/curl/sleep."""
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / '.github/workflows/release-assets.yml'
VERSION = '9.8.7-ci-test'
CONTENT = b'offline fixture package\n'

FAKE = r'''#!/usr/bin/env python3
import json, os, shutil, sys
from pathlib import Path
root = Path(os.environ['FAKE_ROOT'])
command = Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / 'calls.jsonl').open('a') as log:
    log.write(json.dumps([command] + args) + '\n')
if command == 'sleep':
    sys.exit(0)
if command == 'curl':
    url = next(a for a in args if a.startswith('https://'))
    target = Path(args[args.index('-o') + 1])
    if url.endswith('/manifest.json'):
        counter = root / 'counter'
        index = int(counter.read_text()) if counter.exists() else 0
        counter.write_text(str(index + 1))
        sequence = json.loads((root / 'sequence.json').read_text())
        value = sequence[min(index, len(sequence) - 1)]
        if value is None:
            sys.exit(22)
        target.write_text(json.dumps(value))
    else:
        if os.environ.get('FAIL_DOWNLOAD'):
            sys.exit(22)
        target.write_bytes(b'corrupt' if os.environ.get('BAD_HASH') else b'offline fixture package\n')
    sys.exit(0)
if command == 'gh':
    state = root / 'release'
    if args[:2] == ['release', 'view']:
        sys.exit(0 if state.exists() else 1)
    if args[:2] == ['release', 'create']:
        if os.environ.get('FAIL_CREATE'):
            sys.exit(1)
        assert '--verify-tag' in args
        state.touch()
        shutil.copyfile(args[args.index('--notes-file') + 1], root / 'notes')
    elif args[:2] == ['release', 'upload']:
        assert '--clobber' in args
        if os.environ.get('FAIL_UPLOAD'):
            sys.exit(1)
        uploaded = root / 'uploaded'
        uploaded.mkdir(exist_ok=True)
        for name in args[3:]:
            if name != '--clobber':
                shutil.copyfile(name, uploaded / Path(name).name)
    else:
        raise AssertionError(args)
    sys.exit(0)
raise AssertionError(command)
'''


def fixture():
    packages = {}
    for name in ('aether-proxy', 'luci-app-aether-proxy',
                 'luci-i18n-aether-proxy-zh-cn', 'aether-xray', 'xray-core'):
        assets = {}
        for arch in ('all', 'aarch64_generic', 'x86_64', 'mips_24kc'):
            assets[arch] = {}
            for ext in ('ipk', 'apk'):
                sep = '_' if ext == 'ipk' else '-'
                filename = f'{name}{sep}{VERSION}_{arch}.{ext}'
                assets[arch][ext] = {'url': filename, 'sha256': hashlib.sha256(CONTENT).hexdigest()}
        packages[name] = {'current': {'version': VERSION, 'assets': assets},
                          'previous': {'version': 'old', 'assets': {'bad': {}}}}
    return {'schema': 2, 'packages': packages, 'data': {'ignored': {}}}


class ReleaseAssets(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = yaml.safe_load(WORKFLOW.read_text())
        cls.steps = [s['run'] for s in cls.workflow['jobs']['release-assets']['steps'] if 'run' in s]

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        for name in ('gh', 'curl', 'sleep'):
            path = bin_dir / name
            path.write_text(FAKE)
            path.chmod(0o755)
        self.env = dict(os.environ, PATH=f'{bin_dir}:{os.environ["PATH"]}',
                        FAKE_ROOT=str(self.root), GITHUB_ENV=str(self.root / 'env'),
                        TAG='v' + VERSION, REF_TYPE='tag', VERSION=VERSION,
                        CHANNEL_URL='https://offline.invalid/channel-stable',
                        WAIT_SECONDS='5', POLL_SECONDS='1')
        self.manifest = fixture()
        self.sequence([self.manifest])

    def sequence(self, values):
        (self.root / 'sequence.json').write_text(json.dumps(values))

    def run_step(self, index, ok=True):
        result = subprocess.run(['bash', '-c', self.steps[index]], cwd=self.root,
                                env=self.env, capture_output=True, text=True, timeout=15)
        output = result.stdout + result.stderr
        if ok:
            self.assertEqual(result.returncode, 0, output)
        else:
            self.assertNotEqual(result.returncode, 0, output)
        return output

    def run_all(self):
        for index in range(len(self.steps)):
            self.run_step(index)

    def calls(self, command):
        return [entry for line in (self.root / 'calls.jsonl').read_text().splitlines()
                if (entry := json.loads(line))[0] == command]

    def test_yaml_and_bash_syntax(self):
        # BaseLoader preserves YAML 1.2's `on` key (PyYAML SafeLoader uses YAML 1.1).
        workflow = yaml.load(WORKFLOW.read_text(), Loader=yaml.BaseLoader)
        self.assertEqual(set(workflow['on']), {'push', 'workflow_dispatch'})
        self.assertEqual(workflow['on']['push']['tags'], ['v*'])
        self.assertFalse(workflow['on']['workflow_dispatch'])
        self.assertEqual(workflow['permissions'], {'contents': 'write'})
        self.assertEqual(self.workflow['jobs']['release-assets']['env']['WAIT_SECONDS'], '5400')
        self.assertEqual(self.workflow['jobs']['release-assets']['env']['POLL_SECONDS'], '60')
        self.assertNotIn('secrets.', WORKFLOW.read_text())
        for script in self.steps:
            self.assertTrue(script.startswith('set -euo pipefail\n'))
            subprocess.run(['bash', '-n'], input=script, text=True, check=True)

    def test_wait_select_hash_and_idempotent_upload(self):
        old = copy.deepcopy(self.manifest)
        old['packages']['aether-proxy']['current']['version'] = 'old'
        self.sequence([None, old, self.manifest])
        self.run_all()
        self.assertEqual(len(self.calls('sleep')), 2)
        uploaded = self.root / 'uploaded'
        names = {path.name for path in uploaded.iterdir()}
        self.assertEqual(len(names), 28)  # three app packages * four arches * two + core * two * two
        self.assertTrue(all(name.endswith(('.ipk', '.apk')) for name in names))
        self.assertFalse(any('xray-core' in name or 'old' in name for name in names))
        core = [name for name in names if name.startswith('aether-xray')]
        self.assertEqual(len(core), 4)
        self.assertTrue(all('aarch64_generic' in name or 'x86_64' in name for name in core))
        notes = (self.root / 'notes').read_text()
        self.assertIn('Install aether-xray first', notes)
        self.assertIn('aarch64_generic = ARM64', notes)
        self.run_all()
        self.assertEqual({p.name for p in uploaded.iterdir()}, names)
        self.assertEqual(sum(c[1:3] == ['release', 'create'] for c in self.calls('gh')), 1)
        self.assertEqual(sum(c[1:3] == ['release', 'upload'] for c in self.calls('gh')), 2)

    def test_channel_noarch_shape(self):
        # Real channel uses assets.all and architecture-free APK names for app/LuCI/i18n.
        for name, package in self.manifest['packages'].items():
            if name in ('aether-xray', 'xray-core'):
                continue
            assets = package['current']['assets']
            package['current']['assets'] = {'all': assets['all']}
            assets['all']['apk']['url'] = f'{name}-{VERSION}.apk'
            assets['all']['apk']['sha256'] = hashlib.sha256(CONTENT).hexdigest().upper()
        self.sequence([self.manifest])
        self.run_all()
        self.assertEqual(len(list((self.root / 'uploaded').iterdir())), 10)

    def test_creation_failure(self):
        self.run_step(1)
        self.run_step(2)
        self.env['FAIL_CREATE'] = '1'
        self.assertIn('Release creation failed', self.run_step(3, ok=False))
        self.assertFalse(any(c[1:3] == ['release', 'upload'] for c in self.calls('gh')))

    def test_custom_notes(self):
        notes = self.root / 'docs/releases' / f'{VERSION}.md'
        notes.parent.mkdir(parents=True)
        notes.write_text('custom tag notes\n')
        self.run_all()
        self.assertEqual((self.root / 'notes').read_text(), notes.read_text())

    def test_branch_and_unsafe_tag_rejected(self):
        self.env['REF_TYPE'] = 'branch'
        self.assertIn('existing v* version tag', self.run_step(0, ok=False))
        self.env.update(REF_TYPE='tag', TAG='v../../escape')
        self.run_step(0, ok=False)

    def test_manifest_missing_timeout(self):
        self.sequence([None])
        self.env['WAIT_SECONDS'] = '0'
        self.assertIn('manifest 未出现', self.run_step(1, ok=False))

    def test_version_mismatch_timeout(self):
        self.manifest['packages']['aether-proxy']['current']['version'] = 'old'
        self.sequence([self.manifest])
        self.env['WAIT_SECONDS'] = '0'
        self.assertIn('版本不匹配', self.run_step(1, ok=False))

    def test_invalid_manifest_timeout(self):
        self.sequence([{'broken': True}])
        self.env['WAIT_SECONDS'] = '0'
        self.assertIn('invalid manifest', self.run_step(1, ok=False))

    def test_download_failure(self):
        self.run_step(1)
        self.env['FAIL_DOWNLOAD'] = '1'
        self.assertIn('下载失败', self.run_step(2, ok=False))
        self.assertFalse(self.calls('gh'))

    def test_hash_failure(self):
        self.run_step(1)
        self.env['BAD_HASH'] = '1'
        self.assertIn('hash 不符', self.run_step(2, ok=False))
        self.assertFalse(self.calls('gh'))

    def test_upload_failure(self):
        self.run_step(1)
        self.run_step(2)
        self.env['FAIL_UPLOAD'] = '1'
        self.assertIn('上传失败', self.run_step(3, ok=False))

    def test_unsafe_filenames(self):
        for filename in ('../escape.ipk', '/tmp/escape.ipk', 'https://evil/a.ipk',
                         'aether-proxy_foo%2fbar.ipk', 'aether-proxy_foo?bar.ipk',
                         'aether-proxy_foo\\bar.ipk', 'aether-proxy_foo\nbar.ipk',
                         '-evil.ipk', 'aether-proxy_foo..bar.ipk', 'xray-core_foo.ipk'):
            with self.subTest(filename=filename):
                manifest = fixture()
                manifest['packages']['aether-proxy']['current']['assets']['all']['ipk']['url'] = filename
                (self.root / 'manifest.json').write_text(json.dumps(manifest))
                self.assertIn('Unsafe manifest filename', self.run_step(2, ok=False))
        self.assertFalse((self.root / 'calls.jsonl').exists())

    def test_invalid_digest_and_missing_core_arch(self):
        asset = self.manifest['packages']['aether-proxy']['current']['assets']['all']['ipk']
        asset['sha256'] = 'deadbeef'
        (self.root / 'manifest.json').write_text(json.dumps(self.manifest))
        self.assertIn('Invalid manifest sha256', self.run_step(2, ok=False))
        manifest = fixture()
        del manifest['packages']['aether-xray']['current']['assets']['x86_64']
        (self.root / 'manifest.json').write_text(json.dumps(manifest))
        self.run_step(2, ok=False)
        self.assertFalse((self.root / 'calls.jsonl').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
