#!/usr/bin/env python3
"""Offline contracts for the three release entry points (T16.30)."""
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import yaml

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / 'tools/release'
CHANNEL = Path(os.environ.get('CHANNEL_WORKTREE', ROOT.parents[1] / 'aether-proxy-channel-wt' / ROOT.name))
sys.path.insert(0, str(TOOLS))
from stage import write_formal_metadata
import verify
from verify import gate_only_rc, stable_only


def load(path):
    # Preserve the GitHub/YAML 1.2 `on` key, which SafeLoader treats as a boolean.
    return yaml.load(path.read_text(), Loader=yaml.BaseLoader)


class ReleasePaths(unittest.TestCase):
    def channel_steps(self):
        path = CHANNEL / '.github/workflows/promote.yml'
        if not path.is_file():
            self.skipTest('set CHANNEL_WORKTREE to the paired channel checkout')
        return load(path)['jobs']['promote']['steps']

    def channel_step(self, prefix):
        return next(s['run'] for s in self.channel_steps() if s.get('name', '').startswith(prefix))

    def test_formal_push_filter_and_dispatch(self):
        workflow = load(ROOT / '.github/workflows/release-assets.yml')
        self.assertEqual(workflow['on']['push']['tags'], ['v[0-9]+.[0-9]+.[0-9]+-r[0-9]+'])
        inputs = workflow['on']['workflow_dispatch']['inputs']
        self.assertEqual(inputs['tag']['required'], 'true')
        self.assertEqual((inputs['dry_run']['type'], inputs['dry_run']['default']), ('boolean', 'false'))
        steps = workflow['jobs']['release-assets']['steps']
        self.assertTrue(any('gate.py --sha "$BUILD_SHA"' in s.get('run', '') for s in steps))
        self.assertTrue(any('stage.py --formal' in s.get('run', '') for s in steps))
        mutations = [s for s in steps if 'gh release create' in s.get('run', '')]
        self.assertEqual(len(mutations), 1)
        self.assertIn('!inputs.dry_run', mutations[0]['if'])
        for s in steps:
            if 'run' in s:
                subprocess.run(['bash', '-n'], input=s['run'], text=True, check=True)

    def test_entry_points_advertise_dry_run(self):
        self.assertIn('$2 == --dry-run', (TOOLS / 'lib.sh').read_text())
        for entry in ('rc.sh', 'promote-rc.sh', 'release.sh'):
            with self.subTest(entry=entry):
                path = TOOLS / entry
                self.assertTrue(os.access(path, os.X_OK))
                self.assertIn('[--dry-run]', path.read_text())
                subprocess.run(['bash', '-n', path], check=True)
                # Invalid CLI flags must be rejected before any gh/git operation.
                result = subprocess.run([path, '1.2.1', '--not-dry-run'], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Usage:', result.stderr)

    def test_channel_inputs_and_writes(self):
        path = CHANNEL / '.github/workflows/promote.yml'
        if not path.is_file():
            self.skipTest('set CHANNEL_WORKTREE to the paired channel checkout')
        workflow = load(path)
        inputs = workflow['on']['workflow_dispatch']['inputs']
        self.assertEqual(inputs['release_tag']['required'], 'true')
        self.assertEqual((inputs['dry_run']['type'], inputs['dry_run']['default']), ('boolean', 'false'))
        self.assertEqual(inputs['publish_target']['type'], 'choice')
        self.assertEqual(inputs['publish_target']['default'], 'stable')
        self.assertEqual(inputs['publish_target']['options'], ['stable', 'rc'])
        steps = workflow['jobs']['promote']['steps']
        for s in steps:
            run = s.get('run', '')
            if run:
                subprocess.run(['bash', '-n'], input=run, text=True, check=True)
            if 'scripts/publish.sh publisher packages' in run or 'gh release create' in run:
                self.assertIn('!inputs.dry_run', s['if'])

    def test_only_rc_entry_dispatches_rc_target(self):
        lib = (TOOLS / 'lib.sh').read_text()
        self.assertIn('-f "publish_target=$target"', lib)
        rc = (TOOLS / 'rc.sh').read_text()
        self.assertEqual(len(re.findall(r'^\s*promote "\$tag" rc$', rc, re.M)), 2)
        self.assertLess(rc.index('verify rc-gate-only'), rc.rindex('promote "$tag" rc'))
        for name in ('release.sh', 'promote-rc.sh'):
            calls = re.findall(r'^\s*promote (.+)$', (TOOLS / name).read_text(), re.M)
            self.assertEqual(calls, ['"$FORMAL_TAG" stable', '"$FORMAL_TAG" stable'])

    def test_channel_rejects_target_tag_mismatch_before_api(self):
        script = self.channel_step('Download and validate')
        with tempfile.TemporaryDirectory() as tmp:
            for tag, target in (('v1.2.1-r1', 'rc'), ('v1.2.1-r1-rc1', 'stable'), ('v1.2.1-r1', 'other')):
                with self.subTest(tag=tag, target=target):
                    env = dict(os.environ, PATH=f'{tmp}:{os.environ["PATH"]}', APP_REPO='offline/app',
                               RELEASE_TAG=tag, PUBLISH_TARGET=target)
                    gh = Path(tmp) / 'gh'
                    gh.write_text('#!/bin/sh\ntouch called\nexit 99\n')
                    gh.chmod(0o755)
                    result = subprocess.run(['bash', '-c', script], cwd=tmp, env=env, capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('publish_target', result.stderr)
                    self.assertFalse((Path(tmp) / 'called').exists())

    def test_rc_manifest_contains_24_distinct_cells_and_stable_previous(self):
        script = self.channel_step('Preview stable')
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            builder = root / 'publisher/tools/channel'
            builder.mkdir(parents=True)
            shutil.copy(ROOT / 'tools/channel/build.py', builder)
            download, old = root / 'download', root / 'existing'
            download.mkdir()
            old.mkdir()
            prior = {'version': '1.2.0-r4', 'assets': {'all': {'ipk': {
                'url': 'previous.ipk', 'size': 3, 'sha256': hashlib.sha256(b'old').hexdigest()}}}}
            (old / 'previous.ipk').write_bytes(b'old')
            (old / 'manifest.json').write_text(json.dumps({'schema': 2, 'data': {},
                'packages': {name: {'current': prior} for name in verify.NAMES}}))
            entries = []
            for name in verify.NAMES:
                for arch in verify.ARCHES:
                    for fmt in verify.FORMATS:
                        asset = f'{arch}--{name}.{fmt}'
                        (download / asset).write_bytes(asset.encode())
                        entries.append(dict(package=name, arch=arch, format=fmt, asset=asset, version='1.2.1-r1',
                                            sha256=hashlib.sha256(asset.encode()).hexdigest()))
            (download / 'rc-manifest.json').write_text(json.dumps({'rc_tag': 'v1.2.1-r1-rc1', 'commit': 'a' * 40, 'assets': entries}))
            gh = root / 'gh'
            gh.write_text('''#!/bin/sh
if [ "$1" = api ]; then
    echo '[[{"tag_name":"channel-stable","draft":false,"prerelease":false}]]'
elif [ "$1 $2 $3" != 'release download channel-stable' ]; then
    exit 90
fi
''')
            gh.chmod(0o755)
            env = dict(os.environ, PATH=f'{tmp}:{os.environ["PATH"]}', GITHUB_REPOSITORY='offline/channel', PUBLISH_TARGET='rc')
            env.pop('COMPATIBILITY_FILE', None)
            result = subprocess.run(['bash', '-c', script], cwd=tmp, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            out = root / 'rc-channel'
            manifest = json.loads((out / 'manifest.json').read_text())
            self.assertIs(manifest['prerelease'], True)
            matrix = {(name, a, f): value for name, pkg in manifest['packages'].items()
                      for a, formats in pkg['current']['assets'].items() for f, value in formats.items()}
            self.assertEqual(len(matrix), 24)
            for entry in entries:
                cell = matrix[entry['package'], entry['arch'], entry['format']]
                self.assertEqual((cell['url'], cell['sha256']), (entry['asset'], entry['sha256']))
                self.assertEqual(hashlib.sha256((out / cell['url']).read_bytes()).hexdigest(), cell['sha256'])
                self.assertEqual(manifest['packages'][entry['package']]['previous'], prior)
            self.assertEqual((out / 'previous.ipk').read_bytes(), b'old')

    def test_stable_cleans_rc_only_after_success_and_only_when_present(self):
        script = self.channel_step('Sign and publish')
        for exists, success, expected in ((True, True, ['publish', 'delete']), (False, True, ['publish']),
                                          (True, False, ['publish'])):
            with self.subTest(exists=exists, success=success), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                (root / 'scripts').mkdir()
                publish = root / 'scripts/publish.sh'
                publish.write_text(f'#!/bin/sh\necho publish >> calls\nexit {0 if success else 1}\n')
                publish.chmod(0o755)
                gh = root / 'gh'
                found = 'channel-rc' if exists else 'channel-stable'
                gh.write_text(f'#!/bin/sh\nif [ "$1" = api ]; then echo {found};\n'
                              'elif [ "$1 $2 $3" = "release delete channel-rc" ]; then echo delete >> calls;\n'
                              'else exit 91; fi\n')
                gh.chmod(0o755)
                env = dict(os.environ, PATH=f'{tmp}:{os.environ["PATH"]}', GITHUB_REPOSITORY='offline/channel', PUBLISH_TARGET='stable')
                result = subprocess.run(['bash', '-c', script], cwd=tmp, env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, success, result.stderr)
                self.assertEqual((root / 'calls').read_text().splitlines(), expected)

    def test_rc_publish_replaces_old_rc_but_never_publishes_stable(self):
        script = self.channel_step('Sign and publish')
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'rc-channel').mkdir()
            (root / 'rc-channel/manifest.json').write_text('{}')
            gh = root / 'gh'
            gh.write_text('''#!/bin/sh
case "$1 $2 $3" in
    'release delete channel-rc') echo delete >> calls ;;
    'release create channel-rc') echo create >> calls ;;
    api*) echo channel-rc ;;
    *) exit 92 ;;
esac
''')
            gh.chmod(0o755)
            env = dict(os.environ, PATH=f'{tmp}:{os.environ["PATH"]}', GITHUB_REPOSITORY='offline/channel',
                       PUBLISH_TARGET='rc', USIGN='/bin/true', USIGN_SECRET_KEY='dummy')
            result = subprocess.run(['bash', '-c', script], cwd=tmp, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            # No stable publisher is present, and the new RC must survive the job.
            self.assertEqual((root / 'calls').read_text().splitlines(), ['delete', 'create'])

    def test_stable_rejects_prerelease_at_all_levels(self):
        policies = [stable_only]
        path = CHANNEL / '.github/workflows/promote.yml'
        if path.is_file():
            preview = next(s['run'] for s in load(path)['jobs']['promote']['steps']
                           if s.get('name', '').startswith('Preview stable'))
            policy, _ = preview.split("cat > publisher/tools/channel/stable_policy.py <<'PY'\n", 1)[1].split('\nPY\n', 1)
            env = {}
            exec(compile(policy, str(path), 'exec'), env)
            policies.append(env['stable_only'])
            # The guard must also be wired into the builder that publish.sh invokes.
            self.assertIn('stable_only(manifest)', preview)
            self.assertIn('builder.build_manifest = checked', preview)
        for validate in policies:
            validate({'packages': {'aether-proxy': {'current': {'version': '1.2.0-r4'}}}})
            for manifest in ({'prerelease': True}, {'packages': {'aether-proxy': {'previous': {'prerelease': True}}}},
                             {'compatibility': [{'current': {'prerelease': True}}]}):
                with self.assertRaisesRegex(ValueError, 'must not contain prerelease'):
                    validate(manifest)

    def test_tag_kind_must_match_published_release(self):
        path = CHANNEL / '.github/workflows/promote.yml'
        if not path.is_file():
            self.skipTest('set CHANNEL_WORKTREE to the paired channel checkout')
        steps = load(path)['jobs']['promote']['steps']
        script = next(s['run'] for s in steps if s.get('name', '').startswith('Download and validate'))
        for tag, draft, prerelease in (('v1.2.1-r1', True, False), ('v1.2.1-r1', False, True),
                                       ('v1.2.1-r1-rc1', True, True), ('v1.2.1-r1-rc1', False, False)):
            with self.subTest(tag=tag, draft=draft, prerelease=prerelease), tempfile.TemporaryDirectory() as tmp:
                gh = Path(tmp) / 'gh'
                response = json.dumps({'tag_name': tag, 'draft': draft, 'prerelease': prerelease})
                gh.write_text(f'#!/bin/sh\ncase "$2" in */releases/tags/*) echo {shlex.quote(response)};; *) exit 73;; esac\n')
                gh.chmod(0o755)
                env = dict(os.environ, PATH=f'{tmp}:{os.environ["PATH"]}', APP_REPO='offline/app', RELEASE_TAG=tag,
                           PUBLISH_TARGET='rc' if tag.endswith('-rc1') else 'stable')
                result = subprocess.run(['bash', '-c', script], cwd=tmp, env=env, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Draft/prerelease status does not match', result.stderr)
                self.assertFalse((Path(tmp) / 'download').exists())

    def test_rc_promote_dispatches_stable_only_after_release_and_comparison(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            script = shutil.copy(TOOLS / 'promote-rc.sh', root)
            (root / 'lib.sh').write_text('''
set -eu
DRY_RUN=false
INPUT=v1.2.1-r1-rc1
RC_RE='^v.*-rc1$'
APP_REPO=offline/app
verify() {
    case "$1" in
        rc-gate-only) echo 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa v1.2.1-r1' ;;
        stable-matches) echo no ;;
        compare)
            test "$2 $3" = 'v1.2.1-r1 v1.2.1-r1-rc1'
            test -f published-release
            echo compare >> calls
            test "$PROOF" = ok
            ;;
    esac
}
parse_args() { :; }
require_unused() { :; }
push_tag() { echo push >> calls; }
wait_workflow() {
    echo wait >> calls
    test "$2" = release-assets.yml
    if [ "$PROOF" = no-release ]; then return 1; fi
    touch published-release
}
promote() {
    test "$1 $2" = 'v1.2.1-r1 stable'
    echo stable >> calls
}
''')
            for proof, calls in (('no-release', ['push', 'wait']), ('wrong-commit', ['push', 'wait', 'compare']),
                                 ('wrong-hash', ['push', 'wait', 'compare']), ('ok', ['push', 'wait', 'compare', 'stable'])):
                with self.subTest(proof=proof):
                    (root / 'calls').unlink(missing_ok=True)
                    (root / 'published-release').unlink(missing_ok=True)
                    result = subprocess.run(['bash', script], cwd=tmp, env=dict(os.environ, PROOF=proof),
                                            capture_output=True, text=True)
                    self.assertEqual(result.returncode == 0, proof == 'ok', result.stderr)
                    self.assertEqual((root / 'calls').read_text().splitlines(), calls)

    def test_comparison_requires_published_formal_same_commit_and_exact_bytes(self):
        tag, candidate = 'v1.2.1-r1', 'v1.2.1-r1-rc1'
        commit = 'a' * 40
        assets = {f'pkg-{i}.apk': f'package {i}'.encode() for i in range(18)}
        rc = dict(target_tag=tag, commit=commit, assets=[{'source': 'built'}])
        release = {'assets': [{'name': n} for n in assets], 'html_url': 'https://example.invalid/release'}
        for condition, failure in (('unpublished', 'Not published'), ('wrong-commit', 'same gate-only RC commit'),
                                   ('wrong-hash', 'checksum mismatch'), ('ok', None)):
            with self.subTest(condition=condition):
                def download(repo, tag, dest, *patterns):
                    dest.mkdir()
                    for name, content in assets.items():
                        (dest / name).write_bytes(b'wrong' if condition == 'wrong-hash' else content)

                with (patch.object(verify, 'published', return_value=release,
                                    side_effect=ValueError('Not published') if condition == 'unpublished' else None) as published,
                      patch.object(verify, 'commit_for', return_value='b' * 40 if condition == 'wrong-commit' else commit),
                      patch.object(verify, 'read_rc', return_value=rc),
                      patch.object(verify, 'download', side_effect=download),
                      patch.object(verify, 'rc_inventory', return_value={n: hashlib.sha256(v).hexdigest() for n, v in assets.items()}),
                      patch('builtins.print')):
                    if failure:
                        with self.assertRaisesRegex(ValueError, failure):
                            verify.compare('offline/app', tag, candidate)
                    else:
                        verify.compare('offline/app', tag, candidate)
                    published.assert_called_once_with('offline/app', tag)

    def test_only_gate_bytes_can_enter_live_rc_promotion(self):
        self.assertTrue(gate_only_rc({'assets': [{'source': 'built'}]}))
        self.assertFalse(gate_only_rc({'assets': [{'source': 'built'}, {'source': 'published'}]}))

    def test_formal_metadata_preserves_package_versions_and_checksums(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            out = root / 'release-assets'
            out.mkdir()
            versions = {f'package-{i}.apk': '1.2.1-r1' for i in range(18)}
            versions['package-0.apk'] = '26.323.05013~470517b'
            for name in versions:
                (out / name).write_bytes(name.encode())
            write_formal_metadata(out, 'a' * 40, versions)
            recorded = json.loads((root / 'release-inventory.json').read_text())
            self.assertEqual(recorded['commit'], 'a' * 40)
            self.assertEqual(recorded['assets']['package-0.apk']['version'], versions['package-0.apk'])
            self.assertEqual(len(list(out.iterdir())), 18)
            hash0 = hashlib.sha256(b'package-0.apk').hexdigest()
            self.assertIn(f'{hash0}  package-0.apk\n', (root / 'SHA256SUMS').read_text())
            subprocess.run(['sha256sum', '--check', '--strict', '../SHA256SUMS'], cwd=out, check=True,
                           stdout=subprocess.DEVNULL)

    def test_version_comparison_in_selected_channel(self):
        update = ROOT / 'aether-proxy/src/lib/update.uc'
        # Execute the real private comparator, not a Python copy or package-manager ordering.
        source = re.search(r'^function version_parts\(.*?(?=^function file_sha256\()', update.read_text(),
                           re.M | re.S)[0]
        source += '''
let channels = { stable: '1.2.0-r4', rc: '1.2.1-r1' };
if (version_newer(channels.stable, '1.2.1-r1')) exit(1);
if (!version_newer(channels.rc, '1.2.0-r4')) exit(2);
if (version_newer(channels.rc, '1.2.1-r1')) exit(3);
'''
        subprocess.run([ROOT / 'tests/host/ucode', '-e', source], cwd=ROOT, check=True)


if __name__ == '__main__':
    unittest.main()
