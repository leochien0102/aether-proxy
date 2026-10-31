#!/usr/bin/env python3
"""Offline build workflow contracts and executable artifact checks; no SDK/network."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]
PACKAGES = ('aether-proxy', 'luci-app-aether-proxy',
            'luci-i18n-aether-proxy-zh-cn', 'aether-xray', 'chinadns-ng')


class BuildWorkflow(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = yaml.load((ROOT / '.github/workflows/build.yml').read_text(), Loader=yaml.BaseLoader)
        cls.jobs = cls.workflow['jobs']

    def test_paths_packages_and_bash_syntax(self):
        for event in ('push', 'pull_request'):
            paths = self.workflow['on'][event]['paths']
            for package in ('aether-xray', 'chinadns-ng'):
                self.assertIn(package + '/**', paths)
        steps = self.jobs['packages']['steps']
        build = next(s for s in steps if s.get('name') == 'Build OpenWrt packages')
        self.assertTrue(set(PACKAGES) - {'luci-i18n-aether-proxy-zh-cn'} <= set(build['env']['PACKAGES'].split()))
        upload = next(s for s in steps if s.get('name') == 'Upload package artifacts')['with']
        self.assertEqual(upload['name'], 'packages-${{ matrix.sdk }}-${{ matrix.package_arch }}')
        self.assertEqual(upload['path'], 'bin/packages/${{ matrix.package_arch }}/aetherproxy/*')
        self.assertEqual(upload['if-no-files-found'], 'error')
        for job in self.jobs.values():
            for step in job['steps']:
                if 'run' in step:
                    subprocess.run(['bash', '-n'], input=step['run'], text=True, check=True)
        subprocess.run(['bash', '-n', str(ROOT / 'tests/ci/smoke.sh')], check=True)

    def test_smoke_matrix_has_matching_binary_builds(self):
        builds = self.jobs['packages']['strategy']['matrix']['include']
        self.assertEqual(len(builds), 4)
        for cell in self.jobs['smoke']['strategy']['matrix']['include']:
            arch = 'aarch64_generic' if cell['arch'] == 'aarch64' else 'x86_64'
            matching = [b for b in builds if b['sdk'] == cell['sdk'] and b['package_arch'] == arch]
            self.assertEqual(len(matching), 1)
            target = 'armsr-armv8' if arch == 'aarch64_generic' else 'x86_64'
            self.assertEqual(matching[0]['arch'], target + '-' + cell['sdk'])
        download = next(s for s in self.jobs['smoke']['steps'] if s.get('uses') == 'actions/download-artifact@v4')
        self.assertEqual(download['with']['name'],
                         "packages-${{ matrix.sdk }}-${{ matrix.arch == 'aarch64' && 'aarch64_generic' || 'x86_64' }}")

    def test_artifact_checks_require_both_dependencies(self):
        step = next(s for s in self.jobs['packages']['steps'] if s.get('name') == 'Verify package artifacts')
        for arch in ('x86_64', 'aarch64_generic'):
            for ext in ('ipk', 'apk'):
                with self.subTest(arch=arch, ext=ext), tempfile.TemporaryDirectory() as temp:
                    directory = Path(temp) / 'bin/packages' / arch / 'aetherproxy'
                    directory.mkdir(parents=True)
                    env = dict(os.environ, PACKAGE_EXT=ext, PACKAGE_ARCH=arch)
                    artifacts = {}
                    for name in PACKAGES:
                        sep = '_' if ext == 'ipk' else '-'
                        path = directory / f'{name}{sep}1.0-r1.{ext}'
                        path.touch()
                        artifacts[name] = path
                    def run():
                        return subprocess.run(['bash', '-c', step['run']], cwd=temp, env=env,
                                              capture_output=True, text=True)
                    result = run()
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    for name in ('aether-xray', 'chinadns-ng'):
                        artifacts[name].unlink()
                        result = run()
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn('Missing ' + name, result.stdout)
                        artifacts[name].touch()


if __name__ == '__main__':
    unittest.main(verbosity=2)
