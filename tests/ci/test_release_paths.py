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
TAG = 'v1.3.1-r5'
COMMIT = 'a' * 40
sys.path.insert(0, str(TOOLS))
from stage import formal_name, reconcile, write_formal_metadata
import verify


def load(path):
    # Preserve the GitHub/YAML 1.2 `on` key, which SafeLoader treats as a boolean.
    return yaml.load(path.read_text(), Loader=yaml.BaseLoader)


def packages(arch_all=verify.ARCH_ALL):
    for name in verify.NAMES:
        version = '26.323.05013~470517b' if name == 'luci-i18n-aether-proxy-zh-cn' else TAG[1:]
        for arch in ('all',) if name in arch_all else verify.ARCHES:
            for fmt in verify.FORMATS:
                raw = f'{name}_{version}_{arch}.ipk' if fmt == 'ipk' else f'{name}-{version}.apk'
                yield name, arch, fmt, raw, formal_name(name, arch, fmt, raw, arch_all), version


class ReleasePaths(unittest.TestCase):
    def channel_workflow(self):
        path = CHANNEL / '.github/workflows/publish-channel.yml'
        if not path.is_file():
            self.skipTest('set CHANNEL_WORKTREE to the paired channel checkout')
        return load(path)

    def channel_step(self, prefix):
        return next(s['run'] for s in self.channel_workflow()['jobs']['publish']['steps']
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
        run = ' '.join(s.get('run', '') for s in steps)
        self.assertRegex(run, r'stage\.py(\s|$)')
        self.assertNotIn('stage.py --formal', run)
        mutations = [s for s in steps if 'gh release create' in s.get('run', '')]
        self.assertEqual(len(mutations), 1)
        self.assertIn("steps.route.outputs.mode == 'direct' && !inputs.dry_run", mutations[0]['if'])
        self.assertIn('aether-release-inventory-v1', mutations[0]['run'])
        self.check_shell_steps(steps)

    def test_release_entry_advertises_dry_run(self):
        self.assertIn('--dry-run)', (TOOLS / 'lib.sh').read_text())
        path = TOOLS / 'release.sh'
        self.assertTrue(os.access(path, os.X_OK))
        self.assertIn('[--dry-run]', path.read_text())
        subprocess.run(['bash', '-n', path], check=True)
        result = subprocess.run([path, '1.2.1', '--not-dry-run'], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Usage:', result.stderr)

    def test_stage_current_matrix_with_historical_backend(self):
        self.stage_matrix(verify.ARCH_ALL, 20)

    def test_stage_historical_tag(self):
        self.stage_matrix(('aether-proxy', *verify.ARCH_ALL), 18)

    def stage_matrix(self, arch_all, count):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name, slot, fmt, raw, filename, version in packages(arch_all):
                pkg = root / name
                pkg.mkdir(exist_ok=True)
                (pkg / 'Makefile').write_text('PKG_VERSION:=1.3.1\nPKG_RELEASE:=5\n' +
                    ('  PKGARCH:=all\n' if name in arch_all else ''))
                sdk = '24.10.8' if fmt == 'ipk' else '25.12.5'
                for arch in verify.ARCHES if slot == 'all' else (slot,):
                    dest = root / 'artifacts' / f'packages-{sdk}-{arch}'
                    dest.mkdir(parents=True, exist_ok=True)
                    (dest / raw).write_bytes(f'{arch}/{raw}'.encode())
            builder = root / 'tools/channel/build.py'
            builder.parent.mkdir(parents=True)
            builder.write_text(f'PACKAGE_NAMES = {verify.NAMES!r}\nARCH_ALL = {arch_all!r}\n')
            manifest = root / 'old.json'
            manifest.write_text(json.dumps({'packages': {'aether-proxy': {'current': {
                'version': '1.2.0-r1', 'assets': {'all': {}}}}}}))
            git = root / 'git'
            git.write_text(f'#!/bin/sh\necho {COMMIT}\n')
            git.chmod(0o755)
            env = dict(os.environ, TAG=TAG, BUILD_SHA=COMMIT, CHANNEL_MANIFEST=str(manifest),
                       PATH=f'{tmp}:{os.environ["PATH"]}')
            bad = subprocess.run([sys.executable, TOOLS / 'stage.py', '--expected-count', str(count + 1)],
                                 cwd=root, env=env, capture_output=True, text=True)
            self.assertNotEqual(bad.returncode, 0)
            self.assertIn('differs from tagged layout', bad.stderr)
            self.assertFalse((root / 'release-assets').exists())
            subprocess.run([sys.executable, TOOLS / 'stage.py', '--expected-count', str(count)], cwd=root, env=env, check=True)
            out = root / 'release-assets'
            self.assertEqual(len(list(out.iterdir())), count)
            for _, slot, _, raw, filename, _ in packages(arch_all):
                arch = 'aarch64_generic' if slot == 'all' else slot
                self.assertEqual((out / filename).read_bytes(), f'{arch}/{raw}'.encode())

    def test_channel_inputs_and_writes(self):
        workflow = self.channel_workflow()
        inputs = workflow['on']['workflow_dispatch']['inputs']
        self.assertEqual(set(inputs), {'release_tag', 'dry_run', 'request_id', 'expected_count'})
        self.assertEqual(inputs['release_tag']['required'], 'true')
        self.assertEqual((inputs['dry_run']['type'], inputs['dry_run']['default']), ('boolean', 'false'))
        steps = workflow['jobs']['publish']['steps']
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

    def test_formal_inventory_preserves_20_bytes_and_raw_versions_through_preflight(self):
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
            self.assertEqual(len(list(out.iterdir())), 20)
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
        print('PKG_VERSION:=1.3.1\\nPKG_RELEASE:=5')
        if path == 'luci-app-aether-proxy/Makefile': print('LUCI_PKGARCH:=all')
    else:
        sys.stdout.buffer.write((Path(os.environ['APP_ROOT']) / path).read_bytes())
elif args[:2] == ['release', 'download'] and args[2] == os.environ['RELEASE_TAG']:
    shutil.copytree('../release-assets', args[args.index('--dir') + 1])
else:
    sys.exit(f'Unexpected gh command: {args}')
''')
            gh.chmod(0o755)
            env = dict(os.environ, PATH=f'{tmp}:{os.environ["PATH"]}', APP_REPO='offline/app', RELEASE_TAG=TAG,
                       GITHUB_REPOSITORY='offline/channel', APP_ROOT=str(ROOT), COMMIT=COMMIT, PYTHONPATH=str(CHANNEL))
            for condition, reason in (('count', 'exactly 20'), ('commit', 'does not match tag commit'),
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

    def test_native_tag_rejects_legacy_or_swapped_backend(self):
        for arch_all in (('aether-proxy', *verify.ARCH_ALL), verify.ARCH_ALL):
            manifest = {'packages': {}}
            for name, arch, fmt, _, url, version in packages(arch_all):
                record = manifest['packages'].setdefault(name, {'current': {'version': version, 'assets': {}}})
                record['current']['assets'].setdefault(arch, {})[fmt] = dict(url=url, sha256='f' * 64)
            self.assertEqual(len(list(verify.channel_packages(manifest, arch_all))), 24 - 2 * len(arch_all))
            if arch_all == verify.ARCH_ALL:
                slots = manifest['packages']['aether-proxy']['current']['assets']
                slots['x86_64']['apk'] = slots['aarch64_generic']['apk']
            with self.assertRaisesRegex(ValueError, 'architectures|identity'):
                list(verify.channel_packages(manifest, verify.ARCH_ALL))

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
                      patch.object(verify, 'gh', return_value=(ROOT / 'tools/channel/build.py').read_text()),
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


class ReconcilePublishedBytes(unittest.TestCase):
    BUILT = b'gate build bytes (B2)'
    PUBLISHED = b'published bytes (B1)'

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        tmp_path = Path(tmp.name)
        self.out = tmp_path / 'out'
        self.out.mkdir()
        self.manifest_source = tmp_path / 'manifest.json'
        self.published = {}
        self.fetched = []

    def stage_entry(self, package='aether-dns'):
        version, arch, fmt = '1.0.2-r1', 'aarch64_generic', 'apk'
        asset = formal_name(package, arch, fmt, f'{package}-{version}.{fmt}')
        entry = dict(package=package, version=version, arch=arch, format=fmt, asset=asset,
                     sha256=hashlib.sha256(self.BUILT).hexdigest())
        (self.out / asset).write_bytes(self.BUILT)
        return entry

    def published_asset(self, entry, content):
        url = entry['asset']
        self.published[(self.manifest_source.parent / url).as_uri()] = content
        return dict(url=url, sha256=hashlib.sha256(content).hexdigest(), size=len(content))

    def package_record(self, entry, asset, *, arch=None, version=None):
        return {'current': {'version': version or entry['version'],
                            'assets': {arch or entry['arch']: {entry['format']: asset}}}}

    def reconcile(self, entries, manifest):
        self.manifest_source.write_text(json.dumps(manifest))

        def fetch(url):
            self.fetched.append(url)
            if url == self.manifest_source.as_uri():
                return self.manifest_source.read_bytes()
            self.assertIn(url, self.published, f'Unexpected fetch: {url}')
            return self.published[url]

        reconcile(entries, self.out, manifest_source=str(self.manifest_source), fetch=fetch)

    def snapshot(self):
        return {p.name: (p.read_bytes(), p.stat().st_ino) for p in self.out.iterdir()}

    def test_unchanged_version_reuses_published_bytes(self):
        entry = self.stage_entry()
        asset = self.published_asset(entry, self.PUBLISHED)
        manifest = {'packages': {entry['package']: self.package_record(entry, asset)}}

        self.reconcile([entry], manifest)

        self.assertEqual((self.out / entry['asset']).read_bytes(), self.PUBLISHED)
        self.assertEqual(entry['source'], 'published')
        self.assertEqual(entry['sha256'], asset['sha256'])

    def test_different_version_keeps_built_bytes(self):
        entry = self.stage_entry()
        asset = self.published_asset(entry, self.PUBLISHED)
        record = self.package_record(entry, asset, version='1.0.1-r1')
        before = self.snapshot()

        self.reconcile([entry], {'packages': {entry['package']: record}})

        self.assertEqual(self.snapshot(), before)
        self.assertEqual(entry['source'], 'built')
        self.assertEqual(self.fetched, [self.manifest_source.as_uri()])

    def test_missing_package_keeps_built_bytes(self):
        entry = self.stage_entry()
        before = self.snapshot()

        self.reconcile([entry], {'packages': {}})

        self.assertEqual(self.snapshot(), before)
        self.assertEqual(entry['source'], 'built')
        self.assertEqual(self.fetched, [self.manifest_source.as_uri()])

    def test_backend_migration_never_relabels_historical_all_bytes(self):
        entry = self.stage_entry('aether-proxy')
        asset = self.published_asset(entry, self.PUBLISHED)
        old = self.package_record(entry, asset, arch='all', version='1.0.1-r1')
        before = self.snapshot()
        self.reconcile([entry], {'packages': {'aether-proxy': old}})
        self.assertEqual(entry['source'], 'built')
        old['current']['version'] = entry['version']
        with self.assertRaisesRegex(SystemExit, 'Published reconciliation failed'):
            self.reconcile([entry], {'packages': {'aether-proxy': old}})
        self.assertEqual(self.snapshot(), before)

    def test_two_noarch_packages_use_all_assets(self):
        for name in ('luci-app-aether-proxy', 'luci-i18n-aether-proxy-zh-cn'):
            with self.subTest(package=name):
                entry = self.stage_entry(name)
                content = f'published {name}'.encode()
                asset = self.published_asset(entry, content)
                # Deliberately no aarch64_generic key for these entries.
                record = self.package_record(entry, asset, arch='all')

                self.reconcile([entry], {'packages': {name: record}})

                self.assertEqual((self.out / entry['asset']).read_bytes(), content)
                self.assertEqual(entry['source'], 'published')
                self.assertEqual(entry['sha256'], asset['sha256'])

    def test_sha256_mismatch_exits_without_rewriting(self):
        entry = self.stage_entry()
        asset = self.published_asset(entry, self.PUBLISHED)
        asset['sha256'] = hashlib.sha256(self.BUILT).hexdigest()
        manifest = {'packages': {entry['package']: self.package_record(entry, asset)}}
        before = self.snapshot()

        with self.assertRaisesRegex(SystemExit, 'Published sha256 mismatch'):
            self.reconcile([entry], manifest)

        self.assertEqual(self.snapshot(), before)

    def test_size_mismatch_exits_without_rewriting(self):
        entry = self.stage_entry()
        asset = self.published_asset(entry, self.PUBLISHED)
        asset['size'] += 1
        manifest = {'packages': {entry['package']: self.package_record(entry, asset)}}
        before = self.snapshot()

        with self.assertRaisesRegex(SystemExit, 'Published size mismatch'):
            self.reconcile([entry], manifest)

        self.assertEqual(self.snapshot(), before)

    def test_missing_packages_object_exits_without_rewriting(self):
        entry = self.stage_entry()
        before = self.snapshot()

        with self.assertRaisesRegex(SystemExit, 'manifest must contain a packages object'):
            self.reconcile([entry], {})

        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.fetched, [self.manifest_source.as_uri()])


def effective_permissions(workflow, job_name):
    job = workflow['jobs'][job_name]
    return job['permissions'] if 'permissions' in job else workflow.get('permissions')


class WorkflowPermissions(unittest.TestCase):
    READ_ONLY = {'contents': 'read'}
    RELEASE_WRITE = {'contents': 'write'}

    def assert_read_only_workflow(self, workflow, expected_jobs):
        self.assertEqual(workflow.get('permissions'), self.READ_ONLY)
        self.assertEqual(set(workflow['jobs']), set(expected_jobs))
        for job_name in workflow['jobs']:
            self.assertEqual(effective_permissions(workflow, job_name), self.READ_ONLY, job_name)

    def assert_component_release_workflow(self, workflow):
        self.assertEqual(workflow.get('permissions'), self.READ_ONLY)
        self.assertEqual(set(workflow['jobs']), {'build', 'release'})
        self.assertEqual(effective_permissions(workflow, 'build'), self.READ_ONLY)
        self.assertEqual(effective_permissions(workflow, 'release'), self.RELEASE_WRITE)

    def test_build_and_test_workflows_are_read_only(self):
        self.assert_read_only_workflow(
            load(ROOT / '.github/workflows/build.yml'),
            {'detect', 'packages', 'smoke'},
        )
        self.assert_read_only_workflow(
            load(ROOT / '.github/workflows/test.yml'),
            {'host-tests', 'validate-xray', 'validate-nft', 'validate-chinadns'},
        )

    def test_release_component_limits_write_to_release_job(self):
        self.assert_component_release_workflow(
            load(ROOT / '.github/workflows/release-component.yml')
        )

    def test_overbroad_permissions_fail_contract(self):
        build_with_write = load(ROOT / '.github/workflows/build.yml')
        build_with_write['jobs']['packages']['permissions'] = {'contents': 'write'}
        with self.assertRaises(AssertionError):
            self.assert_read_only_workflow(build_with_write, {'detect', 'packages', 'smoke'})

        build_without_top = load(ROOT / '.github/workflows/build.yml')
        del build_without_top['permissions']
        with self.assertRaises(AssertionError):
            self.assert_read_only_workflow(build_without_top, {'detect', 'packages', 'smoke'})

        component_with_top_write = load(ROOT / '.github/workflows/release-component.yml')
        component_with_top_write['permissions'] = {'contents': 'write'}
        with self.assertRaises(AssertionError):
            self.assert_component_release_workflow(component_with_top_write)


if __name__ == '__main__':
    unittest.main()
