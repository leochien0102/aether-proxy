"""Fixture-driven offline published-byte reconciliation and mutation oracles (M4-17)."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest
from unittest.mock import patch

import test_gate as fixtures
import stage

ROOT = Path(__file__).resolve().parents[2]


class ReconciliationTests(unittest.TestCase):
	def setUp(self):
		fixtures.StagingTests.setUp(self)
		self.published = self.root / 'published'
		self.published.mkdir()
		self.manifest = self.published / 'manifest.json'
		self.packages = {}
		self.script = ROOT / 'tools/release/stage.py'
		for directory, ext in fixtures.gate.MATRIX.items():
			arch = directory.split('-', 2)[2]
			for path in (self.root / 'artifacts' / directory).iterdir():
				name = next(n for n in self.names if path.name.startswith(n + ('_' if ext == 'ipk' else '-')))
				pkg_arch = 'all' if name in self.names[:3] else arch
				filename = path.name
				if ext == 'apk' and pkg_arch != 'all':
					filename = f'{path.stem}_{pkg_arch}.apk'
				content = ('published ' + filename).encode()
				(self.published / filename).write_bytes(content)
				current = self.packages.setdefault(name, {'current': {
					'version': '1.2.3-r1', 'assets': {}}})['current']
				current['assets'].setdefault(pkg_arch, {})[ext] = dict(
					url=filename, sha256=hashlib.sha256(content).hexdigest(), size=len(content))
		self.save()

	def save(self):
		self.manifest.write_text(json.dumps({'schema': 2, 'packages': self.packages}))

	def run_stage(self, success=True):
		env = dict(os.environ, CHANNEL_MANIFEST=str(self.manifest), TAG='v1.2.3-r1-rc1',
			BUILD_SHA=fixtures.SHA, PATH=str(self.root / 'fake-bin') + os.pathsep + os.environ['PATH'])
		result = subprocess.run([sys.executable, str(self.script)], cwd=self.root,
			env=env, text=True, capture_output=True)
		self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
		if not success:
			self.assertFalse((self.root / 'rc-assets/rc-manifest.json').exists())
			self.assertFalse((self.root / 'rc-assets/SHA256SUMS').exists())
		return result

	def output(self):
		out = self.root / 'rc-assets'
		entries = json.loads((out / 'rc-manifest.json').read_text())['assets']
		return entries, {e['asset']: (out / e['asset']).read_bytes() for e in entries}

	def assert_published(self):
		entries, contents = self.output()
		for entry in entries:
			with self.subTest(entry=entry):
				self.assertEqual(entry.get('source'), 'published')
				arch = 'all' if entry['package'] in self.names[:3] else entry['arch']
				asset = self.packages[entry['package']]['current']['assets'][arch][entry['format']]
				self.assertEqual(contents[entry['asset']], (self.published / asset['url']).read_bytes())
				self.assertEqual(entry['sha256'], asset['sha256'])

	def test_r1_same_version_different_bytes_uses_published(self):
		self.run_stage()
		self.assert_published()
		entries, contents = self.output()
		for entry in entries:
			sdk = '24.10.8' if entry['format'] == 'ipk' else '25.12.5'
			built = self.root / f'artifacts/packages-{sdk}-{entry["arch"]}' / entry['filename']
			self.assertNotEqual(contents[entry['asset']], built.read_bytes())

	def test_r2_changed_version_uses_built(self):
		self.packages['aether-xray']['current']['version'] = '1.2.2-r1'
		self.save()
		self.run_stage()
		entries, contents = self.output()
		for entry in entries:
			if entry['package'] != 'aether-xray':
				self.assertEqual(entry['source'], 'published')
				continue
			self.assertEqual(entry['source'], 'built')
			sdk = '24.10.8' if entry['format'] == 'ipk' else '25.12.5'
			built = self.root / f'artifacts/packages-{sdk}-{entry["arch"]}' / entry['filename']
			self.assertEqual(contents[entry['asset']], built.read_bytes())

	def test_r3_missing_or_corrupt_asset_fails_closed(self):
		asset = next(iter(self.packages['aether-proxy']['current']['assets']['all'].values()))
		path = self.published / asset['url']
		for content in (None, b'corrupt'):
			with self.subTest(content=content):
				if content is None:
					path.unlink()
				else:
					path.write_bytes(content)
				result = self.run_stage(success=False)
				self.assertIn('Cannot read' if content is None else 'sha256 mismatch', result.stderr)
				shutil.rmtree(self.root / 'rc-assets')

	def test_r3_manifest_errors_and_missing_slot_fail_closed(self):
		for content in (None, '{invalid', '{}', json.dumps({'packages': {
			'aether-proxy': {'current': {'version': '1.2.3-r1', 'assets': {}}}}})):
			with self.subTest(content=content):
				if content is None:
					self.manifest.unlink()
				else:
					self.manifest.write_text(content)
				self.assertIn('Published reconciliation failed', self.run_stage(False).stderr)
				shutil.rmtree(self.root / 'rc-assets')

	def test_r3_network_error_is_not_a_build_fallback(self):
		with patch('stage.urlopen', side_effect=OSError('offline network failure')):
			with self.assertRaisesRegex(SystemExit, 'offline network failure'):
				stage.reconcile([], self.root, 'https://offline.invalid/manifest.json')

	def test_promote_asset_identity_preflight(self):
		# Restore exactly promote's packages/<arch>/rc/<filename> layout and use the
		# unchanged channel generator. Equal bytes must also yield identical metadata.
		from channel.build import collect_packages
		self.run_stage()
		entries, contents = self.output()
		for entry in entries:
			path = self.root / 'restored' / entry['arch'] / 'rc' / entry['filename']
			path.parent.mkdir(parents=True, exist_ok=True)
			path.write_bytes(contents[entry['asset']])
		generated, _, _ = collect_packages(self.root / 'restored')
		for name, package in generated.items():
			self.assertEqual(package, self.packages[name]['current'])

	def test_r4_two_rcs_all_unchanged_have_identical_published_bytes(self):
		self.run_stage()
		self.assert_published()
		_, first = self.output()
		shutil.rmtree(self.root / 'rc-assets')
		for path in (self.root / 'artifacts').rglob('*'):
			if path.is_file():
				path.write_bytes(b'a different gate build')
		self.run_stage()
		self.assert_published()
		self.assertEqual(self.output()[1], first)

	def test_r5_mutations_are_killed_by_r1_and_r3(self):
		original = self.script.read_text()
		mutations = [
			('\treconcile(entries, out)', '\t# reconciliation removed',
				'test_r1_same_version_different_bytes_uses_published'),
			("if hashlib.sha256(content).hexdigest() != digest:", 'if False:',
				'test_r3_missing_or_corrupt_asset_fails_closed')]
		for old, new, oracle in mutations:
			with self.subTest(oracle=oracle):
				# Execute a copy in the same tools layout; never mutate the real implementation.
				copy = self.root / oracle / 'tools/release'
				shutil.copytree(ROOT / 'tools', copy.parent)
				mutant = copy / 'stage.py'
				self.assertEqual(original.count(old), 1)
				mutant.write_text(original.replace(old, new))
				case = ReconciliationTests(oracle)
				case.setUp()
				case.script = mutant
				if 'r3' in oracle:
					# Keep length equal so only the sha256 oracle detects the corruption.
					asset = case.packages['aether-proxy']['current']['assets']['all']['ipk']
					asset['size'] = len(b'corrupt')
					case.save()
				try:
					with self.assertRaises(AssertionError, msg='Mutation survived: ' + oracle):
						getattr(case, oracle)()
				finally:
					case.doCleanups()


if __name__ == '__main__':
	unittest.main()
