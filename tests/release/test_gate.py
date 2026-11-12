"""Offline gate selection and RC staging contract tests (M4-15 / docs/08)."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import yaml
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/release'))
import gate

SHA = 'a' * 40
RUN = dict(id=42, head_sha=SHA, event='push', status='completed', conclusion='success',
	path='.github/workflows/build.yml', run_number=10)


def artifacts():
	return [dict(id=i, name=name, expired=False, size_in_bytes=100,
		expires_at='2099-01-01T00:00:00Z', workflow_run=dict(id=42, head_sha=SHA))
		for i, name in enumerate(gate.MATRIX, 1)]


class SelectionTests(unittest.TestCase):
	def test_success_push_and_dispatch(self):
		for event in ('push', 'workflow_dispatch'):
			self.assertEqual(gate.select_run([dict(RUN, event=event)], SHA)['id'], 42)

	def test_latest_success_only(self):
		self.assertEqual(gate.select_run([RUN, dict(RUN, id=43, run_number=11),
			dict(RUN, id=44, run_number=12, conclusion='failure')], SHA)['id'], 43)

	def test_no_run(self):
		for runs in ([], [dict(RUN, conclusion='failure')], [dict(RUN, status='in_progress')],
			[dict(RUN, event='pull_request')], [dict(RUN, path='.github/workflows/test.yml')]):
			with self.assertRaisesRegex(ValueError, '先让门禁通过'):
				gate.select_run(runs, SHA)

	def test_sha_mismatch(self):
		with self.assertRaisesRegex(ValueError, '先让门禁通过'):
			gate.select_run([RUN], 'b' * 40)
		items = artifacts()
		items[0]['workflow_run']['head_sha'] = 'b' * 40
		with self.assertRaisesRegex(ValueError, 'SHA mismatch'):
			gate.select_artifacts(items, SHA, 42)

	def test_complete_artifacts(self):
		self.assertEqual(len(gate.select_artifacts(artifacts(), SHA, 42)), 4)

	def test_missing_or_duplicate_sdk_matrix(self):
		for items in ([], artifacts()[:-1], artifacts() + [artifacts()[0]]):
			with self.assertRaisesRegex(ValueError, 'SDK artifact matrix'):
				gate.select_artifacts(items, SHA, 42)

	def test_expired_and_wrong_run(self):
		for changes in (dict(expired=True), dict(expires_at='2000-01-01T00:00:00Z'),
			dict(size_in_bytes=0), dict(workflow_run=dict(id=99, head_sha=SHA))):
			items = artifacts()
			items[0].update(changes)
			with self.assertRaisesRegex(ValueError, '先让门禁通过'):
				gate.select_artifacts(items, SHA, 42)

	def test_workflow_reuses_cross_run_ids_without_build(self):
		workflow = yaml.safe_load((ROOT / '.github/workflows/release-candidate.yml').read_text())
		self.assertEqual(set(workflow['jobs']), {'candidate'})
		steps = workflow['jobs']['candidate']['steps']
		download = next(s for s in steps if s.get('uses') == 'actions/download-artifact@v4')['with']
		self.assertEqual(download['run-id'], '${{ steps.gate.outputs.run_id }}')
		self.assertEqual(download['artifact-ids'], '${{ steps.gate.outputs.artifact_ids }}')
		self.assertEqual(download['github-token'], '${{ github.token }}')
		self.assertFalse(download['merge-multiple'])
		for step in steps:
			if 'run' in step:
				subprocess.run(['bash', '-n'], input=step['run'], text=True, check=True)
		build = yaml.safe_load((ROOT / '.github/workflows/build.yml').read_text())
		upload = next(s for s in build['jobs']['packages']['steps']
			if s.get('uses') == 'actions/upload-artifact@v4')['with']
		self.assertEqual(upload['retention-days'], 90)
		cells = build['jobs']['packages']['strategy']['matrix']['include']
		self.assertEqual({f'packages-{c["sdk"]}-{c["package_arch"]}' for c in cells}, set(gate.MATRIX))

	def test_cli_outputs_selected_run_and_ids(self):
		with patch('gate.api_pages', side_effect=[[RUN], artifacts()]), \
			patch('sys.argv', ['gate.py', '--sha', SHA, '--repo', 'owner/repo']), \
			patch('builtins.print') as output:
			gate.main()
		self.assertEqual(output.call_args_list[0].args, ('run_id=42',))
		self.assertEqual(output.call_args_list[1].args, ('artifact_ids=1,2,3,4',))

	def test_pagination(self):
		with patch('gate.subprocess.check_output', return_value=json.dumps([
			{'workflow_runs': [RUN]}, {'workflow_runs': [dict(RUN, id=43)]}])) as call:
			self.assertEqual(len(gate.api_pages('owner/repo', 'endpoint', 'workflow_runs')), 2)
			self.assertIn('--paginate', call.call_args.args[0])


class StagingTests(unittest.TestCase):
	def setUp(self):
		self.temp = tempfile.TemporaryDirectory()
		self.addCleanup(self.temp.cleanup)
		self.root = Path(self.temp.name)
		self.names = ['aether-proxy', 'luci-app-aether-proxy', 'luci-i18n-aether-proxy-zh-cn',
			'aether-xray', 'chinadns-ng']
		# Git is only used to resolve the tag in stage.py; no real repository or release is created.
		(self.root / 'fake-bin').mkdir()
		git = self.root / 'fake-bin/git'
		git.write_text('#!/bin/sh\nprintf "%s\\n" ' + SHA + '\n')
		git.chmod(0o755)
		for name in self.names:
			if name == self.names[2]:
				continue
			(self.root / name).mkdir()
			(self.root / name / 'Makefile').write_text('PKG_VERSION:=1.2.3\nPKG_RELEASE:=1\n')
		for directory, ext in gate.MATRIX.items():
			arch = directory.split('-', 2)[2]
			dest = self.root / 'artifacts' / directory
			dest.mkdir(parents=True)
			for name in self.names:
				pkg_arch = 'all' if name in self.names[:3] else arch
				filename = f'{name}_1.2.3-r1_{pkg_arch}.ipk' if ext == 'ipk' else f'{name}-1.2.3-r1.apk'
				(dest / filename).write_bytes((directory + filename).encode())

	def stage(self):
		manifest = self.root / 'published.json'
		manifest.write_text(json.dumps({'packages': {}}))
		env = dict(os.environ, CHANNEL_MANIFEST=str(manifest), TAG='v1.2.3-r1-rc1', BUILD_SHA=SHA,
			PATH=str(self.root / 'fake-bin') + os.pathsep + os.environ['PATH'])
		return subprocess.run([sys.executable, str(ROOT / 'tools/release/stage.py')],
			cwd=self.root, env=env, text=True, capture_output=True)

	def test_stage_exact_bytes_and_hashes(self):
		result = self.stage()
		self.assertEqual(result.returncode, 0, result.stderr)
		out = self.root / 'rc-assets'
		manifest = json.loads((out / 'rc-manifest.json').read_text())
		self.assertEqual(manifest['commit'], SHA)
		self.assertEqual(len(manifest['assets']), 20)
		for entry in manifest['assets']:
			data = (out / entry['asset']).read_bytes()
			self.assertEqual(entry['sha256'], hashlib.sha256(data).hexdigest())
		for line in (out / 'SHA256SUMS').read_text().splitlines():
			digest, filename = line.split('  ')
			self.assertEqual(digest, hashlib.sha256((out / filename).read_bytes()).hexdigest())
		self.assertEqual(len(list(out.iterdir())), 22)

	def test_reviewed_bridge_is_preserved(self):
		bridge = self.root / 'bridges/compatibility.json'
		bridge.parent.mkdir()
		bridge.write_text(json.dumps({'aether-proxy': {'steps': [{'version': '1.2.3-r1'}]}}))
		result = self.stage()
		self.assertEqual(result.returncode, 0, result.stderr)
		out = self.root / 'rc-assets'
		self.assertEqual((out / 'compatibility.json').read_bytes(), bridge.read_bytes())
		self.assertEqual(json.loads((out / 'rc-manifest.json').read_text())['compatibility'],
			'compatibility.json')
		self.assertIn('compatibility.json', (out / 'SHA256SUMS').read_text())

	def test_stale_bridge_blocks(self):
		bridge = self.root / 'bridges/compatibility.json'
		bridge.parent.mkdir()
		bridge.write_text(json.dumps({'aether-proxy': {'steps': [{'version': 'old'}]}}))
		self.assertIn('terminal step must be the built', self.stage().stderr)

	def test_missing_directory(self):
		first = next((self.root / 'artifacts').iterdir())
		first.rename(self.root / 'removed')
		self.assertNotEqual(self.stage().returncode, 0)

	def test_missing_package(self):
		next((self.root / 'artifacts').rglob('*.ipk')).unlink()
		self.assertNotEqual(self.stage().returncode, 0)

	def test_wrong_name_and_version(self):
		path = next((self.root / 'artifacts').rglob('aether-proxy_*.ipk'))
		for bad in ('unexpected_1.2.3-r1_all.ipk', 'aether-proxy_9.0.0-r1_all.ipk',
			'aether-proxy_1.2.3-r1_wrong.ipk'):
			changed = path.with_name(bad)
			path.rename(changed)
			result = self.stage()
			self.assertNotEqual(result.returncode, 0, bad)
			changed.rename(path)
			if (self.root / 'rc-assets').exists():
				import shutil
				shutil.rmtree(self.root / 'rc-assets')

	def test_wrong_format(self):
		path = next((self.root / 'artifacts').rglob('*.ipk'))
		path.rename(path.with_suffix('.apk'))
		self.assertNotEqual(self.stage().returncode, 0)

	def test_tag_sha_mismatch(self):
		git = self.root / 'fake-bin/git'
		git.write_text('#!/bin/sh\nprintf "%s\\n" ' + 'b' * 40 + '\n')
		self.assertIn('RC tag/commit mismatch', self.stage().stderr)


if __name__ == '__main__':
	unittest.main()
