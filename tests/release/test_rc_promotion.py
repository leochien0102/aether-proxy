#!/usr/bin/env python3
"""Execute the real workflow run blocks offline; no network, tags, or releases.

CHANNEL_ROOT may select a separate channel checkout.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]
CHANNEL = Path(os.environ.get('CHANNEL_ROOT', ROOT.parent.parent / 'aether-proxy-channel-wt' / ROOT.name))
RC = yaml.safe_load((ROOT / '.github/workflows/release-candidate.yml').read_text())
PROMOTE_PATH = CHANNEL / '.github/workflows/promote.yml'
PROMOTE = yaml.safe_load(PROMOTE_PATH.read_text()) if PROMOTE_PATH.is_file() else {}

FAKE = r'''#!/usr/bin/env python3
import json, os, shutil, sys
from pathlib import Path
r = Path(os.environ['FAKE_ROOT']); a = sys.argv[1:]
with (r / 'calls').open('a') as f: f.write(json.dumps([Path(sys.argv[0]).name] + a) + '\n')
if Path(sys.argv[0]).name == 'git':
    print(os.environ['BUILD_SHA']); sys.exit(0)
if a[0] == 'api':
    endpoint = a[-1]
    if '/contents/' in endpoint:
        path = endpoint.split('/contents/')[1].split('?')[0]
        sys.stdout.buffer.write((Path(os.environ['APP_ROOT']) / path).read_bytes())
    elif '/git/ref/' in endpoint:
        sha = os.environ.get('FORMAL_SHA', os.environ['BUILD_SHA']) if endpoint.endswith('-r1') else os.environ.get('TAG_SHA', os.environ['BUILD_SHA'])
        print(json.dumps({'object': {'type': 'commit', 'sha': sha}}))
    elif '/git/matching-refs/' in endpoint:
        print(json.dumps([{'ref': 'refs/tags/v0.6.3-r1'}] if os.environ.get('FORMAL_SHA') else []))
    elif '/releases/tags/' in endpoint:
        print(json.dumps({'tag_name': os.environ['TAG'], 'draft': False,
                          'prerelease': not bool(os.environ.get('NOT_PRERELEASE')),
                          'assets': [{'name': p.name} for p in (r / 'release').iterdir()]}))
    else:
        stable = [{'tag_name': 'channel-stable'}] if os.environ.get('HAS_STABLE') else []
        existing = [{'tag_name': os.environ['TAG']}] if (r / 'release').exists() else []
        print(json.dumps([stable] if '--slurp' in a else existing))
elif a[:2] == ['release', 'create']:
    assert '--prerelease' in a and '--verify-tag' in a and '--latest=false' in a
    dest = r / 'release'; dest.mkdir()
    for p in a[3:]:
        if p.startswith('rc-assets/'): shutil.copy(p, dest)
elif a[:2] == ['release', 'download']:
    source = r / ('stable' if a[2] == 'channel-stable' else 'release')
    if a[2] == 'channel-stable' and not (source / 'manifest.json').exists(): sys.exit(1)
    dest = Path(a[a.index('--dir') + 1]) if '--dir' in a else Path(a[a.index('-D') + 1])
    shutil.copytree(source, dest)
elif a[:2] == ['release', 'view']:
    if '--json' in a: print('\n'.join(p.name for p in (r / 'stable').iterdir()))
    else: sys.exit(0 if (r / 'stable').exists() else 1)
elif a[:2] == ['release', 'upload']:
    dest = r / 'stable'; dest.mkdir(exist_ok=True)
    for p in a[3:]:
        if p != '--clobber': shutil.copy(p, dest)
elif a[:2] == ['release', 'delete-asset']: pass
else: raise AssertionError(a)
'''


@unittest.skipUnless(PROMOTE, 'Set CHANNEL_ROOT to the channel checkout containing promote.yml')
class PromotionTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.app = self.root / 'app'; self.app.mkdir()
        self.work = self.root / 'candidate'; self.work.mkdir()
        self.promote = self.root / 'promote'; self.promote.mkdir()
        for name in ['aether-proxy', 'luci-app-aether-proxy', 'aether-xray', 'chinadns-ng']:
            (self.app / name).mkdir()
            shutil.copy(ROOT / name / 'Makefile', self.app / name / 'Makefile')
            (self.work / name).symlink_to(self.app / name, target_is_directory=True)
        shutil.copytree(ROOT / 'tools', self.app / 'tools')
        bin_dir = self.root / 'bin'; bin_dir.mkdir()
        for name in ['gh', 'git']:
            p = bin_dir / name; p.write_text(FAKE); p.chmod(0o755)
        self.env = dict(os.environ, FAKE_ROOT=str(self.root), APP_ROOT=str(self.app),
                        TAG='v0.6.3-rc1', RC_TAG='v0.6.3-rc1', BUILD_SHA='a' * 40,
                        GH_REPO='offline/app', APP_REPO='offline/app', GITHUB_REPOSITORY='offline/channel',
                        PATH=str(bin_dir) + ':' + os.environ['PATH'])
        self.names = ['aether-proxy', 'luci-app-aether-proxy', 'luci-i18n-aether-proxy-zh-cn', 'aether-xray', 'chinadns-ng']
        versions = ['0.6.3', '0.6.3', '26.001.12345~abcdef0', '26.10.31', '2025.08.09']
        for sdk, ext in [('24.10.8', 'ipk'), ('25.12.5', 'apk')]:
            for arch in ['aarch64_generic', 'x86_64']:
                d = self.work / f'artifacts/packages-{sdk}-{arch}'; d.mkdir(parents=True)
                for i, (n, v) in enumerate(zip(self.names, versions)):
                    v += '' if i == 2 else '-r1'
                    filename = f'{n}_{v}_{"all" if i < 3 else arch}.ipk' if ext == 'ipk' else f'{n}-{v}.apk'
                    (d / filename).write_bytes((filename + arch).encode())

    def run_step(self, workflow, index, cwd, success=True):
        job = 'candidate' if workflow is RC else 'promote'
        steps = [s for s in workflow['jobs'][job]['steps'] if 'run' in s]
        p = subprocess.run(['bash', '-c', steps[index]['run']], cwd=cwd, env=self.env,
                           text=True, capture_output=True)
        self.assertEqual(p.returncode == 0, success, p.stdout + p.stderr)
        return p

    def candidate(self):
        self.run_step(RC, 0, self.work)
        self.run_step(RC, 1, self.work)

    def test_round_trip_and_sign(self):
        self.candidate()
        self.assertEqual(len(list((self.root / 'release').iterdir())), 22)
        self.run_step(PROMOTE, 0, self.promote)
        self.run_step(PROMOTE, 1, self.promote)
        # Real publisher and channel generator, offline data and signer substitutes only.
        data = self.promote / 'publisher/tools/data/build.py'
        data.write_text('import pathlib,sys\np=pathlib.Path(sys.argv[sys.argv.index("--out")+1]);p.mkdir()\n'
                        'for n in ["gfwlist","chnlist","apple","chnroute4","gfw_static4"]: (p/(n+".txt")).write_text("fixture\\n")\n')
        signer = self.root / 'signer'
        signer.write_text('#!/bin/bash\nset -eu\nif [[ "$1" == -S ]]; then printf signature > "$3.sig"; fi\n')
        signer.chmod(0o755)
        (self.root / 'stable').mkdir()
        self.env.update(USIGN=str(signer), USIGN_SECRET_KEY='FAKE TEST KEY')
        p = subprocess.run(['bash', str(CHANNEL / 'scripts/publish.sh'), str(self.promote / 'publisher'), str(self.promote / 'packages')],
                           cwd=self.promote, env=self.env, text=True, capture_output=True)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        stable = self.root / 'stable'
        self.assertTrue((stable / 'manifest.json.sig').exists())
        manifest = json.loads((stable / 'manifest.json').read_text())
        for entry in manifest['packages'].values():
            for formats in entry['current']['assets'].values():
                for asset in formats.values():
                    content = (stable / asset['url']).read_bytes()
                    self.assertEqual(hashlib.sha256(content).hexdigest(), asset['sha256'])
                    self.assertIn(content, [p.read_bytes() for p in (self.root / 'release').iterdir()])

    def test_bad_hash_blocks(self):
        self.candidate()
        next((self.root / 'release').glob('*.ipk')).write_bytes(b'corrupt')
        self.run_step(PROMOTE, 0, self.promote, False)
        self.assertFalse((self.promote / 'packages').exists())

    def test_missing_asset_blocks(self):
        self.candidate(); next((self.root / 'release').glob('*.apk')).unlink()
        self.run_step(PROMOTE, 0, self.promote, False)

    def test_not_prerelease_blocks(self):
        self.candidate(); self.env['NOT_PRERELEASE'] = '1'
        self.run_step(PROMOTE, 0, self.promote, False)

    def test_wrong_commit_blocks(self):
        self.candidate(); self.env['TAG_SHA'] = 'b' * 40
        self.run_step(PROMOTE, 0, self.promote, False)

    def test_formal_tag_commit_mismatch_blocks(self):
        self.candidate(); self.env['FORMAL_SHA'] = 'b' * 40
        self.run_step(PROMOTE, 0, self.promote, False)

    def test_formal_tag_same_commit_allowed(self):
        self.candidate(); self.env['FORMAL_SHA'] = self.env['BUILD_SHA']
        self.run_step(PROMOTE, 0, self.promote)

    def test_existing_rc_never_replaced(self):
        self.candidate()
        self.run_step(RC, 1, self.work, False)
        calls = (self.root / 'calls').read_text()
        self.assertEqual(calls.count('"release", "create"'), 1)

    def test_manifest_hash_blocks_even_with_updated_checksums(self):
        self.candidate()
        directory = self.root / 'release'
        manifest = directory / 'rc-manifest.json'
        value = json.loads(manifest.read_text()); value['assets'][0]['sha256'] = '0' * 64
        manifest.write_text(json.dumps(value))
        sums = directory / 'SHA256SUMS'
        sums.write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.name + '\n'
                                for p in sorted(directory.iterdir()) if p != sums))
        self.run_step(PROMOTE, 0, self.promote, False)

    def test_wrong_target_version_blocks(self):
        self.candidate()
        p = self.app / 'aether-proxy/Makefile'
        p.write_text(p.read_text().replace('0.6.3', '9.9.9'))
        self.run_step(PROMOTE, 0, self.promote, False)

    def test_missing_build_artifact_never_uploads(self):
        next((self.work / 'artifacts').rglob('*.ipk')).unlink()
        self.run_step(RC, 0, self.work, False)
        self.assertFalse((self.root / 'release').exists())

    def test_tag_version_mismatch_never_uploads(self):
        self.env['TAG'] = 'v9.9.9-rc1'
        self.run_step(RC, 0, self.work, False)

    def stable_fixture(self):
        self.candidate()
        self.run_step(PROMOTE, 0, self.promote)
        self.run_step(PROMOTE, 1, self.promote)
        shutil.copytree(self.promote / 'preflight', self.root / 'stable')
        shutil.rmtree(self.promote / 'preflight')
        self.env['HAS_STABLE'] = '1'

    def test_existing_identical_bytes_allowed(self):
        self.stable_fixture()
        self.run_step(PROMOTE, 1, self.promote)

    def test_existing_different_bytes_blocks(self):
        self.stable_fixture()
        next((self.root / 'stable').glob('*.ipk')).write_bytes(b'different stable bytes')
        self.run_step(PROMOTE, 1, self.promote, False)
        self.assertNotIn('release", "upload', (self.root / 'calls').read_text())

    def test_same_version_different_manifest_blocks(self):
        self.stable_fixture()
        p = self.root / 'stable/manifest.json'
        m = json.loads(p.read_text())
        m['packages']['aether-proxy']['current']['assets']['all']['ipk']['sha256'] = '0' * 64
        p.write_text(json.dumps(m))
        self.run_step(PROMOTE, 1, self.promote, False)

    def test_inconsistent_translation_blocks_before_upload(self):
        p = next((self.work / 'artifacts').rglob('luci-i18n*.ipk'))
        p.rename(p.with_name(p.name.replace('26.001', '26.002')))
        self.run_step(RC, 0, self.work, False)
        self.assertFalse((self.root / 'release').exists())

    def test_workflow_contract_and_shell_syntax(self):
        for directory in [ROOT, CHANNEL]:
            for path in (directory / '.github/workflows').glob('*.yml'):
                self.assertIsInstance(yaml.safe_load(path.read_text()), dict, str(path))
        build = yaml.safe_load((ROOT / '.github/workflows/build.yml').read_text())
        self.assertIn('workflow_call', build.get('on', build.get(True)))
        self.assertEqual(RC['jobs']['candidate']['needs'], 'build')
        steps = PROMOTE['jobs']['promote']['steps']
        self.assertEqual(sum(s.get('uses', '').startswith('actions/checkout@') for s in steps), 1)
        text = json.dumps(steps)
        for forbidden in ['gh-action-sdk', 'make ', 'scripts/usign.sh', 'src/aether-proxy', 'gcc ', 'go build']:
            self.assertNotIn(forbidden, text)
        self.assertNotIn('USIGN_SECRET_KEY', json.dumps(steps[:-1]))
        for workflow, job in [(RC, 'candidate'), (PROMOTE, 'promote')]:
            for step in workflow['jobs'][job]['steps']:
                if 'run' in step:
                    p = subprocess.run(['bash', '-n'], input=step['run'], text=True, capture_output=True)
                    self.assertEqual(p.returncode, 0, p.stderr)


if __name__ == '__main__':
    unittest.main()
