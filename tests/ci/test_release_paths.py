#!/usr/bin/env python3
"""Offline contracts for the formal Release and stable publication paths."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import yaml

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / 'tools/release'
CHANNEL = Path(os.environ.get('CHANNEL_WORKTREE', ROOT.parents[1] / 'aether-proxy-channel-wt' / ROOT.name))
TAG = 'v1.2.1-r1'
COMMIT = 'a' * 40
sys.path.insert(0, str(TOOLS))
from stage import formal_name, write_formal_metadata
import verify


def load(path):
    # Preserve the GitHub/YAML 1.2 `on` key, which SafeLoader treats as a boolean.
    return yaml.load(path.read_text(), Loader=yaml.BaseLoader)


def packages():
    for name in verify.NAMES:
        version = '26.323.05013~470517b' if name == verify.ARCH_ALL[2] else TAG[1:]
        for arch in ('all',) if name in verify.ARCH_ALL else verify.ARCHES:
            for fmt in verify.FORMATS:
                raw = f'{name}_{version}_{arch}.ipk' if fmt == 'ipk' else f'{name}-{version}.apk'
                yield name, arch, fmt, raw, formal_name(name, arch, fmt, raw), version


class ReleasePaths(unittest.TestCase):
    def channel_workflow(self):
        path = CHANNEL / '.github/workflows/promote.yml'
        if not path.is_file():
            self.skipTest('set CHANNEL_WORKTREE to the paired channel checkout')
        return load(path)

    def channel_step(self, prefix):
        return next(s['run'] for s in self.channel_workflow()['jobs']['promote']['steps']
                    if s.get('name', '').startswith(prefix))

    def check_shell_steps(self, steps):
        for step in steps:
            if 'run' in step:
                subprocess.run(['bash', '-n'], input=step['run'], text=True, check=True)

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
        self.assertIn("steps.route.outputs.mode == 'direct' && !inputs.dry_run", mutations[0]['if'])
        self.assertIn('aether-release-inventory-v1', mutations[0]['run'])
        self.check_shell_steps(steps)

    def test_release_entry_advertises_dry_run(self):
        self.assertIn('$2 == --dry-run', (TOOLS / 'lib.sh').read_text())
        path = TOOLS / 'release.sh'
        self.assertTrue(os.access(path, os.X_OK))
        self.assertIn('[--dry-run]', path.read_text())
        subprocess.run(['bash', '-n', path], check=True)
        result = subprocess.run([path, '1.2.1', '--not-dry-run'], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Usage:', result.stderr)

    def test_channel_inputs_and_writes(self):
        workflow = self.channel_workflow()
        inputs = workflow['on']['workflow_dispatch']['inputs']
        self.assertEqual(set(inputs), {'release_tag', 'dry_run', 'request_id'})
        self.assertEqual(inputs['release_tag']['required'], 'true')
        self.assertEqual((inputs['dry_run']['type'], inputs['dry_run']['default']), ('boolean', 'false'))
        steps = workflow['jobs']['promote']['steps']
        self.check_shell_steps(steps)
        self.assertEqual([s['uses'] for s in steps if 'uses' in s], ['actions/checkout@v4'])
        self.assertNotIn('with', steps[0])  # Checkout is channel only.
        writes = [s for s in steps if 'scripts/publish.sh publisher packages' in s.get('run', '')]
        self.assertEqual(len(writes), 1)
        self.assertIn('!inputs.dry_run', writes[0]['if'])

    def test_stable_rejects_prerelease_at_all_levels(self):
        preview = self.channel_step('Preview stable')
        policy = preview.split("cat > publisher/tools/channel/stable_policy.py <<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
        env = {}
        exec(compile(policy, 'stable_policy.py', 'exec'), env)
        self.assertIn('stable_only(manifest)', preview)
        self.assertIn('builder.build_manifest = checked', preview)
        for validate in (verify.stable_only, env['stable_only']):
            validate({'packages': {'aether-proxy': {'current': {'version': '1.2.0-r4'}}}})
            for manifest in ({'prerelease': True}, {'packages': {'aether-proxy': {'previous': {'prerelease': True}}}},
                             {'compatibility': [{'current': {'prerelease': True}}]}):
                with self.assertRaisesRegex(ValueError, 'must not contain prerelease'):
                    validate(manifest)

    def test_only_matching_published_formal_tag_is_accepted(self):
        script = self.channel_step('Download and validate')
        cases = ((TAG + '-test', TAG, False, False, 'Expected a formal'),
                 (TAG, TAG, True, False, 'Draft/prerelease status does not match'),
                 (TAG, TAG, False, True, 'Draft/prerelease status does not match'),
                 (TAG, 'v1.2.0-r1', False, False, 'Draft/prerelease status does not match'))
        for tag, released, draft, prerelease, reason in cases:
            with self.subTest(tag=tag, released=released, draft=draft, prerelease=prerelease), tempfile.TemporaryDirectory() as tmp:
                gh = Path(tmp) / 'gh'
                response = json.dumps({'tag_name': released, 'draft': draft, 'prerelease': prerelease})
                gh.write_text(f'#!/bin/sh\ncase "$2" in */releases/tags/*) touch called; echo \'{response}\';; *) exit 73;; esac\n')
                gh.chmod(0o755)
                env = dict(os.environ, PATH=f'{tmp}:{os.environ["PATH"]}', APP_REPO='offline/app', RELEASE_TAG=tag)
                result = subprocess.run(['bash', '-c', script], cwd=tmp, env=env, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(reason, result.stderr)
                self.assertEqual((Path(tmp) / 'called').exists(), tag == TAG)
                self.assertFalse((Path(tmp) / 'download').exists())

    def test_formal_inventory_preserves_18_bytes_and_raw_versions_through_preflight(self):
        validate = self.channel_step('Download and validate')
        preview = self.channel_step('Preview stable')
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            out = root / 'release-assets'
            out.mkdir()
            versions = {}
            for _, _, _, _, filename, version in packages():
                (out / filename).write_bytes(filename.encode())
                versions[filename] = version
            write_formal_metadata(out, COMMIT, versions)
            subprocess.run(['sha256sum', '--check', '--strict', '../SHA256SUMS'], cwd=out, check=True,
                           stdout=subprocess.DEVNULL)
            self.assertEqual(len(list(out.iterdir())), 18)
            gh = root / 'gh'
            gh.write_text('''#!/usr/bin/env python3
import json, os, shutil, sys
from pathlib import Path
args = sys.argv[1:]
if args[0] == 'api' and args[-1].endswith('/releases?per_page=100'):
    print('[]')
elif args[0] == 'api' and '/releases/tags/' in args[1]:
    print(Path('../release.json').read_text())
elif args[0] == 'api' and '/git/ref/tags/' in args[1]:
    print(json.dumps({'object': {'type': 'commit', 'sha': os.environ['COMMIT']}}))
elif args[0] == 'api' and '/contents/' in args[-1]:
    path, ref = args[-1].split('/contents/', 1)[1].split('?ref=')
    assert ref == os.environ['COMMIT']
    if path.endswith('/Makefile'):
        print('PKG_VERSION:=1.2.1\\nPKG_RELEASE:=1')
    else:
        sys.stdout.buffer.write((Path(os.environ['APP_ROOT']) / path).read_bytes())
elif args[:2] == ['release', 'download'] and args[2] == os.environ['RELEASE_TAG']:
    shutil.copytree('../release-assets', args[args.index('--dir') + 1])
else:
    sys.exit(f'Unexpected gh command: {args}')
''')
            gh.chmod(0o755)
            env = dict(os.environ, PATH=f'{tmp}:{os.environ["PATH"]}', APP_REPO='offline/app', RELEASE_TAG=TAG,
                       GITHUB_REPOSITORY='offline/channel', APP_ROOT=str(ROOT), COMMIT=COMMIT)
            for condition, reason in (('count', 'exactly 18'), ('commit', 'does not match tag commit'),
                                      ('hash', 'SHA-256 mismatch'), ('ok', None)):
                with self.subTest(condition=condition):
                    work = root / condition
                    work.mkdir()
                    inventory = json.loads((root / 'release-inventory.json').read_text())
                    assets = [{'name': n} for n in sorted(versions)]
                    if condition == 'count':
                        assets.pop()
                    elif condition == 'commit':
                        inventory['commit'] = 'b' * 40
                    elif condition == 'hash':
                        inventory['assets'][next(iter(versions))]['sha256'] = '0' * 64
                    body = f'Notes\n<!-- aether-release-inventory-v1\n{json.dumps(inventory)}\n-->'
                    (root / 'release.json').write_text(json.dumps(dict(tag_name=TAG, draft=False, prerelease=False,
                                                                       body=body, assets=assets)))
                    result = subprocess.run(['bash', '-c', validate], cwd=work, env=env, capture_output=True, text=True)
                    if reason:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn(reason, result.stderr)
                        continue
                    self.assertEqual(result.returncode, 0, result.stderr)
                    result = subprocess.run(['bash', '-c', preview], cwd=work, env=env, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.count('(Release = proposed stable)'), 24)
                    self.assertEqual({p.name for p in (work / 'packages').rglob('*') if p.is_file()},
                                     {raw for _, _, _, raw, _, _ in packages()})
                    for _, _, _, _, filename, _ in packages():
                        self.assertEqual((work / 'preflight' / filename).read_bytes(), (out / filename).read_bytes())

    def test_compare_rejects_extra_reference(self):
        result = subprocess.run([sys.executable, TOOLS / 'verify.py', 'compare', 'offline/app', TAG, 'extra-tag'],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('compare accepts only the app repository and formal tag', result.stderr)

    def test_direct_when_stable_is_absent_or_at_another_version(self):
        old = {'packages': {'aether-proxy': {'current': {'version': '1.2.0-r1'}}}}
        for manifest in (None, old):
            with (patch.object(verify, 'stable_manifest', return_value=manifest),
                  patch.object(verify, 'compare_bytes') as compare, patch('builtins.print') as output):
                verify.publication_route('offline/app', TAG, COMMIT)
                compare.assert_not_called()
                output.assert_called_once_with('mode=direct')

    def test_stable_rerun_requires_formal_release_and_identical_downloads(self):
        manifest = {'packages': {}}
        assets = {}
        for name, arch, fmt, _, filename, version in packages():
            assets[filename] = filename.encode()
            entry = manifest['packages'].setdefault(name, {'current': {'version': version, 'assets': {}}})
            entry['current']['assets'].setdefault(arch, {})[fmt] = dict(
                url=filename, sha256=hashlib.sha256(assets[filename]).hexdigest())
        release = {'assets': [{'name': n} for n in assets], 'html_url': 'https://example.invalid/release'}
        for condition, failure in (('wrong-commit', 'tag commit changed'), ('unpublished', 'Not published'),
                                   ('formal', 'Release/stable checksum mismatch'), ('stable', 'do not match its manifest'),
                                   ('ok', None)):
            with self.subTest(condition=condition):
                def download(repo, tag, dest, *patterns):
                    dest.mkdir()
                    for name, content in assets.items():
                        (dest / name).write_bytes(b'wrong' if dest.name == condition else content)

                with (patch.object(verify, 'stable_manifest', return_value=manifest),
                      patch.object(verify, 'commit_for', return_value='b' * 40 if condition == 'wrong-commit' else COMMIT),
                      patch.object(verify, 'published', return_value=release,
                                   side_effect=ValueError('Not published') if condition == 'unpublished' else None),
                      patch.object(verify, 'download', side_effect=download), patch('builtins.print') as output):
                    if failure:
                        with self.assertRaisesRegex(ValueError, failure):
                            verify.publication_route('offline/app', TAG, COMMIT)
                        output.assert_not_called()
                    else:
                        verify.publication_route('offline/app', TAG, COMMIT)
                        self.assertEqual(output.call_args.args, ('mode=channel',))


if __name__ == '__main__':
    unittest.main()
