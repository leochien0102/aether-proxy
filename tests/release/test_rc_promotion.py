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
import fnmatch, json, os, shutil, sys
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
    patterns = [v for k, v in zip(a, a[1:]) if k == '-p']
    if not patterns:
        shutil.copytree(source, dest)
    else:
        # gh treats -p as globs and fails when nothing matches.
        dest.mkdir(parents=True, exist_ok=True)
        matched = [p for p in source.iterdir() if any(fnmatch.fnmatch(p.name, t) for t in patterns)]
        for p in matched: shutil.copy(p, dest / p.name)
        if not matched: sys.exit(1)
elif a[:2] == ['release', 'view']:
    if '--json' in a: print('\n'.join(p.name for p in (r / 'stable').iterdir()))
    else: sys.exit(0 if (r / 'stable').exists() else 1)
elif a[:2] == ['release', 'upload']:
    dest = r / 'stable'; dest.mkdir(exist_ok=True)
    for p in a[3:]:
        if p != '--clobber' and Path(p).name != os.environ.get('DROP_UPLOAD'): shutil.copy(p, dest)
elif a[:2] == ['release', 'delete-asset']: (r / 'stable' / a[3]).unlink()
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
        # The RC step imports the shared canonical-version rule from the checkout's tools.
        (self.work / 'tools').symlink_to(self.app / 'tools', target_is_directory=True)
        bin_dir = self.root / 'bin'; bin_dir.mkdir()
        for name in ['gh', 'git']:
            p = bin_dir / name; p.write_text(FAKE); p.chmod(0o755)
        self.env = dict(os.environ, FAKE_ROOT=str(self.root), APP_ROOT=str(self.app),
                        TAG='v0.6.3-rc1', RC_TAG='v0.6.3-rc1', BUILD_SHA='a' * 40,
                        GH_REPO='offline/app', APP_REPO='offline/app', GITHUB_REPOSITORY='offline/channel',
                        GITHUB_ENV=str(self.root / 'github_env'),
                        PATH=str(bin_dir) + ':' + os.environ['PATH'])
        for name in ['COMPATIBILITY_FILE', 'DROP_UPLOAD']:
            self.env.pop(name, None)
        self.names = ['aether-proxy', 'luci-app-aether-proxy', 'luci-i18n-aether-proxy-zh-cn', 'aether-xray', 'chinadns-ng']
        # Real published naming (h28k-test/pkg061-063, same bytes as the releases): standard
        # packages render "-<release>", the luci.mk-built luci-app renders "-r<release>", the
        # translation package carries its own version without a release. ipk and apk of one
        # package share the version string (the generator's one-version rule needs it).
        self.package_versions = {
            'aether-proxy': '0.6.3-1', 'luci-app-aether-proxy': '0.6.3-r1',
            'luci-i18n-aether-proxy-zh-cn': '26.304.48628~fda7280',
            'aether-xray': '26.10.31-1', 'chinadns-ng': '2025.08.09-1'}
        for sdk, ext in [('24.10.8', 'ipk'), ('25.12.5', 'apk')]:
            for arch in ['aarch64_generic', 'x86_64']:
                d = self.work / f'artifacts/packages-{sdk}-{arch}'; d.mkdir(parents=True)
                for n, v in self.package_versions.items():
                    filename = f'{n}_{v}_{"all" if n in self.names[:3] else arch}.ipk' if ext == 'ipk' else f'{n}-{v}.apk'
                    (d / filename).write_bytes((filename + arch).encode())

    def run_step(self, workflow, index, cwd, success=True):
        job = 'candidate' if workflow is RC else 'promote'
        steps = [s for s in workflow['jobs'][job]['steps'] if 'run' in s]
        p = subprocess.run(['bash', '-c', steps[index]['run']], cwd=cwd, env=self.env,
                           text=True, capture_output=True)
        # Steps hand values forward exactly like Actions does through GITHUB_ENV.
        github_env = Path(self.env['GITHUB_ENV'])
        if github_env.exists():
            for line in github_env.read_text().splitlines():
                name, _, value = line.partition('=')
                if name:
                    self.env[name] = value
            github_env.unlink()
        self.assertEqual(p.returncode == 0, success, p.stdout + p.stderr)
        return p

    def candidate(self):
        self.run_step(RC, 0, self.work)
        self.run_step(RC, 1, self.work)

    def prepare_publisher(self, expected_assets=22):
        self.candidate()
        self.assertEqual(len(list((self.root / 'release').iterdir())), expected_assets)
        self.run_step(PROMOTE, 0, self.promote)
        self.run_step(PROMOTE, 1, self.promote)
        # Real publisher and channel generator, offline data and signer substitutes only.
        data = self.promote / 'publisher/tools/data/build.py'
        data.write_text('import pathlib,sys\np=pathlib.Path(sys.argv[sys.argv.index("--out")+1]);p.mkdir()\n'
                        'for n in ["gfwlist","chnlist","apple","chnroute4","gfw_static4"]: (p/(n+".txt")).write_text("fixture\\n")\n')
        signer = self.root / 'signer'
        signer.write_text('#!/bin/bash\nset -eu\nif [[ "$1" == -S ]]; then printf signature > "$3.sig"; fi\n')
        signer.chmod(0o755)
        (self.root / 'stable').mkdir(exist_ok=True)
        self.env.update(USIGN=str(signer), USIGN_SECRET_KEY='FAKE TEST KEY')

    def publish(self, packages=True, success=True):
        args = ['bash', str(CHANNEL / 'scripts/publish.sh'), str(self.promote / 'publisher')]
        if packages:
            args.append(str(self.promote / 'packages'))
        result = subprocess.run(args, cwd=self.promote, env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def bridge_fixture(self):
        # Synthetic publish.sh-side chain (bytes are fake; versions follow the real
        # renderings). The terminal step must equal the built aether-proxy 0.6.3-1.
        directory = self.root / 'bridge input'; directory.mkdir()
        steps = []
        predecessor = '0.6.1-r1'
        for version in ['0.6.2-r1', '0.6.3-1']:
            assets = {'all': {}}
            for kind in ['ipk', 'apk']:
                filename = f'bridge-{version}.{kind}'
                content = filename.encode()
                (directory / filename).write_bytes(content)
                assets['all'][kind] = dict(url=filename, size=len(content),
                                           sha256=hashlib.sha256(content).hexdigest())
            steps.append(dict(version=version, min_from=predecessor, assets=assets, reason='Offline bridge'))
            predecessor = version
        compatibility = {'aether-proxy': {'required_steps': [s['version'] for s in steps], 'steps': steps}}
        path = directory / 'compatibility.json'; path.write_text(json.dumps(compatibility))
        self.env['COMPATIBILITY_FILE'] = str(path)
        return compatibility, {a['url'] for s in steps for a in s['assets']['all'].values()}

    def rc_bridge_fixture(self):
        """Synthetic chain for the promote path — NOT a published chain and never committed
        to the app repo. The terminal step carries the RC's own noarch artifacts (the
        aarch64_generic copy the generator keeps); the intermediate step's bytes sit in the
        fake stable channel. Versions follow the real published renderings so the terminal
        step matches the built aether-proxy."""
        stable = self.root / 'stable'; stable.mkdir()
        (stable / 'manifest.json').write_text(json.dumps(
            {'schema': 2, 'generated': '2026-01-01T00:00:00Z', 'packages': {}, 'data': {}}))
        assets, historical = {}, {}
        for kind, sdk, filename in [('ipk', '24.10.8', 'aether-proxy_0.6.3-1_all.ipk'),
                                    ('apk', '25.12.5', 'aether-proxy-0.6.3-1.apk')]:
            content = (self.work / f'artifacts/packages-{sdk}-aarch64_generic' / filename).read_bytes()
            assets[kind] = dict(url=filename, size=len(content), sha256=hashlib.sha256(content).hexdigest())
        for kind, filename in [('ipk', 'aether-proxy_0.6.2-1_all.ipk'), ('apk', 'aether-proxy-0.6.2-1.apk')]:
            content = f'synthetic bridge bytes {filename}'.encode()
            (stable / filename).write_bytes(content)
            historical[kind] = dict(url=filename, size=len(content), sha256=hashlib.sha256(content).hexdigest())
        steps = [dict(version='0.6.2-1', min_from='0.6.1-1', assets={'all': historical},
                      reason='Synthetic intermediate step'),
                 dict(version='0.6.3-1', min_from='0.6.2-1', assets={'all': assets},
                      reason='Synthetic target step')]
        compatibility = {'aether-proxy': {'required_steps': ['0.6.2-1', '0.6.3-1'], 'steps': steps}}
        (self.work / 'bridges').mkdir()
        (self.work / 'bridges/compatibility.json').write_text(json.dumps(compatibility))
        return compatibility, {a['url'] for s in steps for a in s['assets']['all'].values()}

    def rename_artifacts(self, prefix, old, new):
        """Re-render versions in all four artifact directories (both formats)."""
        for d in (self.work / 'artifacts').iterdir():
            for p in sorted(d.iterdir()):
                if p.name.startswith(prefix + '_') or p.name.startswith(prefix + '-'):
                    p.rename(p.with_name(p.name.replace(old, new)))

    def tamper_rc_compatibility(self, text):
        """Replace the staged compatibility.json and restage SHA256SUMS, as a forged RC would."""
        release = self.root / 'release'
        (release / 'compatibility.json').write_text(text)
        sums = release / 'SHA256SUMS'
        sums.write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.name + '\n'
                                for p in sorted(release.iterdir()) if p != sums))

    def test_round_trip_and_sign(self):
        self.prepare_publisher()
        self.publish()
        stable = self.root / 'stable'
        self.assertNotIn('compatibility', json.loads((stable / 'manifest.json').read_text()))
        self.assertTrue((stable / 'manifest.json.sig').exists())
        manifest = json.loads((stable / 'manifest.json').read_text())
        for entry in manifest['packages'].values():
            for formats in entry['current']['assets'].values():
                for asset in formats.values():
                    content = (stable / asset['url']).read_bytes()
                    self.assertEqual(hashlib.sha256(content).hexdigest(), asset['sha256'])
                    self.assertIn(content, [p.read_bytes() for p in (self.root / 'release').iterdir()])

    def test_publisher_bridge_upload_and_data_only_retention(self):
        self.prepare_publisher()
        compatibility, urls = self.bridge_fixture()
        self.publish()
        stable = self.root / 'stable'
        self.assertEqual(json.loads((stable / 'manifest.json').read_text())['compatibility'], compatibility)
        self.assertTrue(all((stable / url).is_file() for url in urls))
        # A data-only run has no local bridge bytes and must retain signed references.
        del self.env['COMPATIBILITY_FILE']
        shutil.rmtree(self.root / 'bridge input')
        (stable / 'stale.ipk').write_bytes(b'stale')
        data = self.promote / 'publisher/tools/data/build.py'
        data.write_text(data.read_text().replace('fixture', 'updated fixture'))
        before = {url: (stable / url).read_bytes() for url in urls}
        self.publish(packages=False)
        self.assertEqual(json.loads((stable / 'manifest.json').read_text())['compatibility'], compatibility)
        self.assertEqual({url: (stable / url).read_bytes() for url in urls}, before)
        self.assertFalse((stable / 'stale.ipk').exists())
        calls = [json.loads(line) for line in (self.root / 'calls').read_text().splitlines()]
        self.assertFalse(any(c[1:3] == ['release', 'delete-asset'] and c[4] in urls for c in calls))

    def test_publisher_without_compatibility_keeps_old_retention_rules(self):
        self.prepare_publisher()
        self.publish()
        stable = self.root / 'stable'
        manifest = json.loads((stable / 'manifest.json').read_text())
        entry = manifest['packages']['aether-proxy']
        (stable / 'previous.ipk').write_bytes(b'previous')
        entry['previous'] = {'version': '0.6.2-r1', 'assets': {'all': {'ipk': {'url': 'previous.ipk'}}}}
        (stable / 'manifest.json').write_text(json.dumps(manifest))
        (stable / 'unreferenced-bridge.ipk').write_bytes(b'not referenced')
        data = self.promote / 'publisher/tools/data/build.py'
        data.write_text(data.read_text().replace('fixture', 'updated fixture'))
        self.publish(packages=False)
        updated = json.loads((stable / 'manifest.json').read_text())
        self.assertNotIn('compatibility', updated)
        self.assertEqual(updated['packages'], manifest['packages'])
        self.assertTrue((stable / 'previous.ipk').exists())
        self.assertFalse((stable / 'unreferenced-bridge.ipk').exists())
        for entry in updated['packages'].values():
            for release in [entry.get('current'), entry.get('previous')]:
                for formats in (release or {}).get('assets', {}).values():
                    for asset in formats.values():
                        self.assertTrue((stable / asset['url']).is_file())
        for asset in updated['data'].values():
            self.assertTrue((stable / asset['url']).is_file())

    def test_publisher_invalid_bridge_contract_or_bytes_blocks(self):
        self.prepare_publisher()
        compatibility, urls = self.bridge_fixture()
        path = Path(self.env['COMPATIBILITY_FILE'])
        for value in [None, {}, {'aether-proxy': {'steps': []}}]:
            with self.subTest(value=value):
                path.write_text(json.dumps(value))
                self.publish(success=False)
                self.assertFalse((self.root / 'stable/manifest.json').exists())
        path.write_text(json.dumps(compatibility))
        asset = path.parent / sorted(urls)[0]
        asset.write_bytes(b'tampered bridge')
        result = self.publish(success=False)
        self.assertIn('hash/size mismatch', result.stderr)
        asset.unlink()
        result = self.publish(success=False)
        self.assertIn('missing compatibility asset', result.stderr)
        self.assertNotIn('release", "upload', (self.root / 'calls').read_text())
        self.assertFalse((self.root / 'stable/manifest.json').exists())

    def test_publisher_bad_compatibility_input_fails_before_release_operations(self):
        self.prepare_publisher()
        path = self.root / 'invalid.json'
        for value in [None, '{invalid', '']:
            with self.subTest(value=value):
                if value is not None:
                    path.write_text(value)
                self.env['COMPATIBILITY_FILE'] = str(path)
                (self.root / 'calls').write_text('')
                self.publish(success=False)
                self.assertEqual((self.root / 'calls').read_text(), '')
        self.env['COMPATIBILITY_FILE'] = ''
        self.publish(success=False)
        self.assertEqual((self.root / 'calls').read_text(), '')

    def test_publisher_missing_bridge_upload_blocks_manifest_switch(self):
        self.prepare_publisher()
        _, urls = self.bridge_fixture()
        self.env['DROP_UPLOAD'] = sorted(urls)[0]
        result = self.publish(success=False)
        self.assertIn('referenced assets missing after upload', result.stderr)
        self.assertFalse((self.root / 'stable/manifest.json').exists())
        self.assertNotIn('delete-asset', (self.root / 'calls').read_text())

    def test_publisher_missing_inherited_bridge_blocks_manifest_switch(self):
        self.prepare_publisher()
        _, urls = self.bridge_fixture()
        self.publish()
        stable = self.root / 'stable'
        old = (stable / 'manifest.json').read_bytes()
        (stable / sorted(urls)[0]).unlink()
        del self.env['COMPATIBILITY_FILE']
        data = self.promote / 'publisher/tools/data/build.py'
        data.write_text(data.read_text().replace('fixture', 'updated fixture'))
        result = self.publish(packages=False, success=False)
        self.assertIn('neither in the release nor built now', result.stderr)
        self.assertEqual((stable / 'manifest.json').read_bytes(), old)
        self.assertNotIn('delete-asset', (self.root / 'calls').read_text())

    def test_bad_hash_blocks(self):
        self.candidate()
        next((self.root / 'release').glob('*.ipk')).write_bytes(b'corrupt')
        self.run_step(PROMOTE, 0, self.promote, False)
        self.assertFalse((self.promote / 'packages').exists())

    def test_missing_asset_blocks(self):
        self.candidate(); next((self.root / 'release').glob('*.apk')).unlink()
        self.run_step(PROMOTE, 0, self.promote, False)

    def test_promote_carries_reviewed_bridge_chain_to_stable(self):
        compatibility, urls = self.rc_bridge_fixture()
        self.prepare_publisher(expected_assets=23)
        self.assertEqual(self.env.get('COMPATIBILITY_FILE'),
                         str((self.promote / 'bridge' / 'compatibility.json').resolve()))
        self.assertTrue(all((self.promote / 'bridge' / url).is_file() for url in urls))
        self.publish()
        stable = self.root / 'stable'
        manifest = json.loads((stable / 'manifest.json').read_text())
        self.assertEqual(manifest['compatibility'], compatibility)
        for url in urls:
            reviewed = next(a for s in compatibility['aether-proxy']['steps']
                            for a in s['assets']['all'].values() if a['url'] == url)
            content = (stable / url).read_bytes()
            self.assertEqual(hashlib.sha256(content).hexdigest(), reviewed['sha256'])
        calls = [json.loads(line) for line in (self.root / 'calls').read_text().splitlines()]
        self.assertFalse(any(c[1:3] == ['release', 'delete-asset'] and c[4] in urls for c in calls))

    def test_promote_missing_bridge_asset_blocks(self):
        self.rc_bridge_fixture()
        (self.root / 'stable' / 'aether-proxy-0.6.2-1.apk').unlink()
        self.candidate()
        p = self.run_step(PROMOTE, 0, self.promote, False)
        self.assertIn('neither in the RC prerelease', p.stderr)
        self.assertNotIn('COMPATIBILITY_FILE', self.env)
        self.assertNotIn('release", "upload', (self.root / 'calls').read_text())

    def test_promote_bridge_hash_mismatch_blocks(self):
        self.rc_bridge_fixture()
        (self.root / 'stable' / 'aether-proxy_0.6.2-1_all.ipk').write_bytes(b'tampered historical')
        self.candidate()
        p = self.run_step(PROMOTE, 0, self.promote, False)
        self.assertIn('Bridge asset hash/size mismatch', p.stderr)
        self.assertNotIn('COMPATIBILITY_FILE', self.env)

    def test_promote_rejects_reviewed_hash_differing_from_rc_bytes(self):
        self.rc_bridge_fixture()
        self.candidate()
        value = json.loads((self.root / 'release' / 'compatibility.json').read_text())
        value['aether-proxy']['steps'][1]['assets']['all']['ipk']['sha256'] = '0' * 64
        self.tamper_rc_compatibility(json.dumps(value))
        p = self.run_step(PROMOTE, 0, self.promote, False)
        self.assertIn('Bridge asset hash/size mismatch', p.stderr)

    def test_promote_requires_ipk_and_apk_bridge_assets(self):
        self.rc_bridge_fixture()
        self.candidate()
        value = json.loads((self.root / 'release' / 'compatibility.json').read_text())
        del value['aether-proxy']['steps'][1]['assets']['all']['apk']
        self.tamper_rc_compatibility(json.dumps(value))
        p = self.run_step(PROMOTE, 0, self.promote, False)
        self.assertIn('needs ipk and apk', p.stderr)

    def test_promote_rejects_invalid_compatibility_json(self):
        self.rc_bridge_fixture()
        self.candidate()
        self.tamper_rc_compatibility('{invalid')
        p = self.run_step(PROMOTE, 0, self.promote, False)
        self.assertIn('not valid JSON', p.stderr)

    def test_promote_rejects_chain_not_ending_at_built_version(self):
        # The terminal step is the built aether-proxy; a chain aimed at another version
        # fails before any bridge byte is downloaded.
        self.rc_bridge_fixture()
        self.candidate()
        value = json.loads((self.root / 'release' / 'compatibility.json').read_text())
        value['aether-proxy']['steps'][-1]['version'] = '0.6.2-1'
        self.tamper_rc_compatibility(json.dumps(value))
        p = self.run_step(PROMOTE, 0, self.promote, False)
        self.assertIn('terminal step must be the built aether-proxy 0.6.3-1', p.stderr)
        self.assertFalse((self.promote / 'bridge').exists())

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

    def test_real_renderings_pass_version_checks_end_to_end(self):
        # The default fixture IS the real published naming: aether-proxy renders "-1",
        # luci-app renders "-r1" (luci.mk), the translation carries its own version. The
        # old PKG_VERSION-rPKG_RELEASE assumption would have killed these; both workflows
        # must accept them and keep the filename version as the manifest version.
        self.candidate()
        self.run_step(PROMOTE, 0, self.promote)
        self.run_step(PROMOTE, 1, self.promote)
        manifest = json.loads((self.promote / 'preflight/manifest.json').read_text())
        self.assertEqual(manifest['packages']['aether-proxy']['current']['version'], '0.6.3-1')
        self.assertEqual(manifest['packages']['luci-app-aether-proxy']['current']['version'], '0.6.3-r1')
        self.assertEqual(manifest['packages']['chinadns-ng']['current']['version'], '2025.08.09-1')

    def test_alternate_release_rendering_accepted(self):
        # A package may render -r<release> instead of -<release>; both appear in real
        # releases, so the accepted set has both and the version is never rewritten.
        self.rename_artifacts('aether-proxy', '0.6.3-1', '0.6.3-r1')
        self.candidate()
        self.run_step(PROMOTE, 0, self.promote)
        manifest = json.loads((self.root / 'release' / 'rc-manifest.json').read_text())
        self.assertEqual(next(e['version'] for e in manifest['assets'] if e['package'] == 'aether-proxy'),
                         '0.6.3-r1')

    def test_mixed_release_rendering_blocks(self):
        # ipk and apk of one package must carry the same version string: two renderings
        # would make the manifest version (and device comparisons) ambiguous.
        for d in (self.work / 'artifacts').iterdir():
            for p in sorted(d.iterdir()):
                if p.suffix == '.apk' and p.name.startswith('aether-proxy-'):
                    p.rename(p.with_name(p.name.replace('0.6.3-1', '0.6.3-r1')))
        self.run_step(RC, 0, self.work, False)
        self.assertFalse((self.root / 'release').exists())

    def test_makefile_mismatch_blocks(self):
        # A stale artifact matching neither Makefile rendering is rejected, whichever
        # rendering the other packages use.
        self.rename_artifacts('aether-xray', '26.10.31-1', '26.10.30-1')
        self.run_step(RC, 0, self.work, False)
        self.assertFalse((self.root / 'release').exists())

    def test_rc_carries_reviewed_compatibility_file(self):
        self.rc_bridge_fixture()
        self.candidate()
        release = self.root / 'release'
        self.assertEqual(len(list(release.iterdir())), 23)
        manifest = json.loads((release / 'rc-manifest.json').read_text())
        self.assertEqual(manifest['compatibility'], 'compatibility.json')
        sums = (release / 'SHA256SUMS').read_text()
        self.assertIn(hashlib.sha256((release / 'compatibility.json').read_bytes()).hexdigest(), sums)

    def test_rc_rejects_invalid_compatibility_file(self):
        directory = self.work / 'bridges'; directory.mkdir()
        path = directory / 'compatibility.json'
        for value in ['{invalid', '[]', '{"aether-proxy": {"steps": [{"version": "0.6.2-r1"}]}}']:
            with self.subTest(value=value):
                path.write_text(value)
                self.run_step(RC, 0, self.work, False)
                self.assertFalse((self.root / 'release').exists())

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
        p.rename(p.with_name(p.name.replace('26.304.48628', '26.305.48628')))
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
