#!/usr/bin/env python3
"""Offline contracts for the three release entry points (T16.30)."""
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / 'tools/release'
CHANNEL = Path(os.environ.get('CHANNEL_WORKTREE', ROOT.parents[1] / 'aether-proxy-channel-wt' / ROOT.name))
sys.path.insert(0, str(TOOLS))
from stage import write_formal_metadata
from verify import gate_only_rc, stable_only


def load(path):
    # Preserve the GitHub/YAML 1.2 `on` key, which SafeLoader treats as a boolean.
    return yaml.load(path.read_text(), Loader=yaml.BaseLoader)


class ReleasePaths(unittest.TestCase):
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
        steps = workflow['jobs']['promote']['steps']
        for s in steps:
            run = s.get('run', '')
            if run:
                subprocess.run(['bash', '-n'], input=run, text=True, check=True)
            if 'scripts/publish.sh publisher packages' in run or 'gh release create' in run:
                self.assertIn('!inputs.dry_run', s['if'])
        publish = next(s['run'] for s in steps if 'scripts/publish.sh publisher packages' in s.get('run', ''))
        self.assertLess(publish.index('gh release create channel-rc'), publish.index('scripts/publish.sh publisher packages'))
        self.assertLess(publish.index('scripts/publish.sh publisher packages'), publish.rindex('gh release delete channel-rc'))

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
                env = dict(os.environ, PATH=f'{tmp}:{os.environ["PATH"]}', APP_REPO='offline/app', RELEASE_TAG=tag)
                result = subprocess.run(['bash', '-c', script], cwd=tmp, env=env, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Draft/prerelease status does not match', result.stderr)
                self.assertFalse((Path(tmp) / 'download').exists())

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
