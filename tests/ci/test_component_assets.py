#!/usr/bin/env python3
"""Offline fixtures go through the same CLI that release-component.yml invokes."""
import contextlib
import gzip
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock
import zlib

ROOT = Path(__file__).resolve().parents[2]
ENTRY = ROOT / 'tools/release/collect_component.py'
spec = importlib.util.spec_from_file_location('collector', ENTRY)
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)
COMPONENT = 'aether-xray'
VERSION = '26.11.9-r1'


def tar(entries):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode='w', format=tarfile.USTAR_FORMAT) as archive:
        for name, data in entries.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mtime = 0
            archive.addfile(info, io.BytesIO(data))
    return gzip.compress(stream.getvalue(), mtime=0)


def ipk(name, version, arch):
    control = f'Package: {name}\nVersion: {version}\nArchitecture: {arch}\nDescription: offline fixture\n'.encode()
    return tar({'debian-binary': b'2.0\n', 'control.tar.gz': tar({'./control': control}),
                'data.tar.gz': tar({'./usr/share/fixture': b'fixture payload\n'})})


def apk(name, version, arch):
    # Real APK v3 ADB schema, not a tar pretending to be APK or mocked metadata.
    # Layout independently constructed from apk-tools 3.0.5 adb.h/apk_adb.h:
    # 8-byte ADB header; typed blob offsets; aligned counted objects; pckg schema.
    database = bytearray(8)

    def string(text):
        raw = text.encode()
        offset = len(database)
        database.extend(bytes([len(raw)]) + raw)
        return 0x80000000 | offset

    def obj(fields, kind=0xe0000000):
        database.extend(bytes((-len(database)) % 4))
        offset = len(database)
        database.extend(struct.pack('<' + 'I' * (len(fields) + 1), len(fields) + 1, *fields))
        return kind | offset

    name_ref, version_ref, arch_ref = string(name), string(version), string(arch)
    description, license_ref = string('offline fixture'), string('MIT')
    info = obj([name_ref, version_ref, 0, description, arch_ref, license_ref])
    paths = obj([], 0xd0000000)
    root = obj([info, paths])
    struct.pack_into('<I', database, 4, root)
    size = 4 + len(database)
    block = struct.pack('<I', size) + database + bytes((-size) % 8)
    raw = b'ADB.pckg' + block
    compressor = zlib.compressobj(level=9, wbits=-15)
    return b'ADBd' + compressor.compress(raw) + compressor.flush()


def fixture(fmt, name, version, arch):
    return ipk(name, version, arch) if fmt == 'ipk' else apk(name, version, arch)


class ComponentAssets(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='component-assets-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.artifacts = self.root / 'artifacts'
        self.output = self.root / 'assets'
        self.files = []
        for sdk, arch, fmt in collector.SLOTS:
            directory = self.artifacts / f'packages-{sdk}-{arch}'
            directory.mkdir(parents=True)
            base = (f'{COMPONENT}_{VERSION}_{arch}.ipk' if fmt == 'ipk'
                    else f'{COMPONENT}-{VERSION}.apk')
            path = directory / base
            path.write_bytes(fixture(fmt, COMPONENT, VERSION, arch))
            (directory / 'Packages.manifest').write_text('ignored index, not a package\n')
            self.files.append(path)

    def run_collector(self, success=True, message=None, component=COMPONENT):
        result = subprocess.run([sys.executable, str(ENTRY), '--artifacts', str(self.artifacts),
                                 '--output', str(self.output), '--component', component,
                                 '--version', VERSION], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0 if success else 1, result.stdout + result.stderr)
        if not success:
            self.assertFalse(self.output.exists(), result.stdout + result.stderr)
            self.assertEqual(list(self.root.glob('.assets-*')), [])
            if message:
                self.assertIn(message, result.stderr)
        return result

    def test_four_slots_hashes_and_metadata(self):
        result = self.run_collector()
        records = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(len(records), 4)
        self.assertEqual(len(list(self.output.iterdir())), 5)
        lines = (self.output / 'SHA256SUMS').read_text().splitlines()
        self.assertEqual(len(lines), 4)
        for record, source, (_, arch, fmt) in zip(records, self.files, collector.SLOTS):
            target = self.output / record['asset']
            self.assertEqual(target.read_bytes(), source.read_bytes())
            self.assertEqual(record['metadata'], [COMPONENT, VERSION, arch])
            self.assertEqual(collector.metadata(target.read_bytes(), fmt), (COMPONENT, VERSION, arch))
            self.assertEqual(record['sha256'], hashlib.sha256(target.read_bytes()).hexdigest())
            self.assertNotIn(f'_{arch}_{arch}', target.name)
        for line in lines:
            checksum, name = line.split('  ')
            self.assertEqual(checksum, hashlib.sha256((self.output / name).read_bytes()).hexdigest())
        check = subprocess.run(['sha256sum', '--check', 'SHA256SUMS'], cwd=self.output, capture_output=True)
        self.assertEqual(check.returncode, 0)
        print('\nEVIDENCE input tree / expected=actual metadata / output / sha256:')
        for record, source in zip(records, self.files):
            print(source.relative_to(self.root), json.dumps(record, sort_keys=True))

    def test_other_existing_components(self):
        for component in ('aether-dns', 'chinadns-ng'):
            with self.subTest(component=component):
                for index, (_, arch, fmt) in enumerate(collector.SLOTS):
                    source = self.files[index]
                    source.unlink()
                    base = (f'{component}_{VERSION}_{arch}.ipk' if fmt == 'ipk'
                            else f'{component}-{VERSION}.apk')
                    self.files[index] = source.with_name(base)
                    self.files[index].write_bytes(fixture(fmt, component, VERSION, arch))
                self.run_collector(component=component)
                shutil.rmtree(self.output)

    def test_apk_uncompressed(self):
        for index in (2, 3):
            self.files[index].write_bytes(zlib.decompress(self.files[index].read_bytes()[4:], -15))
        self.run_collector()

    def test_apk_bad_object_offset_and_truncated_stream(self):
        path = self.files[2]
        original = path.read_bytes()
        raw = bytearray(zlib.decompress(original[4:], -15))
        # root offset in database header (file 8 + block header 4 + root field 4).
        struct.pack_into('<I', raw, 16, 0xeffffffc)
        for data in (bytes(raw), original[:-5]):
            with self.subTest(data_length=len(data)):
                path.write_bytes(data)
                self.run_collector(False)
        path.write_bytes(original)

    def test_staging_failures_leave_no_publishable_output(self):
        # Fault injection exercises the production collect function itself; normal
        # acceptance cases above still launch precisely the workflow's CLI.
        original_read = Path.read_bytes
        original_write = Path.write_bytes

        def failed_write(path, data):
            if path.parent.name.startswith('.assets-') and path.suffix == '.apk':
                raise OSError('injected staging write failure')
            return original_write(path, data)

        def corrupt_read(path):
            data = original_read(path)
            return data + b'corruption' if path.parent.name.startswith('.assets-') else data

        faults = [('write', mock.patch.object(Path, 'write_bytes', failed_write), OSError),
                  ('checksum', mock.patch.object(Path, 'read_bytes', corrupt_read), ValueError),
                  ('rename', mock.patch.object(collector.os, 'rename', side_effect=OSError('injected rename failure')), OSError)]
        for label, patcher, error in faults:
            with self.subTest(fault=label), patcher, contextlib.redirect_stdout(io.StringIO()), self.assertRaises(error):
                collector.collect(self.artifacts, self.output, COMPONENT, VERSION)
            self.assertFalse(self.output.exists())
            self.assertEqual(list(self.root.glob('.assets-*')), [])

    def test_missing_slot(self):
        shutil.rmtree(self.files[0].parent)
        self.run_collector(False, 'artifact slots')

    def test_missing_package(self):
        self.files[0].unlink()
        self.run_collector(False, 'got 0')

    def test_duplicate(self):
        shutil.copyfile(self.files[0], self.files[0].with_name('duplicate.ipk'))
        self.run_collector(False, 'got 2')

    def test_wrong_identity_each_format(self):
        for index in (0, 2):
            for field, value in ((0, 'chinadns-ng'), (1, '99.0-r1'), (2, 'aarch64_generic')):
                with self.subTest(index=index, field=field):
                    sdk, arch, fmt = collector.SLOTS[index]
                    identity = [COMPONENT, VERSION, arch]
                    identity[field] = value
                    self.files[index].write_bytes(fixture(fmt, *identity))
                    self.run_collector(False, 'expected metadata')
                    self.files[index].write_bytes(fixture(fmt, COMPONENT, VERSION, arch))

    def test_wrong_extension_slot(self):
        self.files[0].rename(self.files[0].with_suffix('.apk'))
        self.run_collector(False, 'wrong format')

    def test_wrong_actual_format(self):
        self.files[2].write_bytes(self.files[0].read_bytes())
        self.run_collector(False, 'expected APK v3')

    def test_corrupt_package(self):
        for index in (0, 2):
            with self.subTest(index=index):
                old = self.files[index].read_bytes()
                self.files[index].write_bytes(b'not a package')
                self.run_collector(False)
                self.files[index].write_bytes(old)

    def test_output_collision(self):
        # Both identities are correct, but two IPK inputs claim the same asset name.
        self.files[1].rename(self.files[1].with_name(self.files[0].name))
        self.run_collector(False, 'output name collision')

    def test_apk_suffix_once(self):
        for index in (2, 3):
            arch = collector.SLOTS[index][1]
            self.files[index] = self.files[index].rename(
                self.files[index].with_name(self.files[index].stem + f'_{arch}.apk'))
        self.run_collector()
        self.assertEqual(len(list(self.output.glob('*.apk'))), 2)

    def test_repeated_or_wrong_suffix_rejected(self):
        path = self.files[2]
        path.rename(path.with_name(path.stem + '_x86_64_x86_64.apk'))
        self.run_collector(False, 'invalid output name')

    def test_extra_slot(self):
        (self.artifacts / 'packages-25.12.5-all').mkdir()
        self.run_collector(False, 'artifact slots')

    def test_no_overwrite(self):
        self.output.mkdir()
        sentinel = self.output / 'existing-release-byte'
        sentinel.write_bytes(b'unchanged')
        result = subprocess.run([sys.executable, str(ENTRY), '--artifacts', str(self.artifacts),
                                 '--output', str(self.output), '--component', COMPONENT,
                                 '--version', VERSION], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('output already exists', result.stderr)
        self.assertEqual(list(self.output.iterdir()), [sentinel])
        self.assertEqual(sentinel.read_bytes(), b'unchanged')

    def test_old_merged_layout_red(self):
        merged = self.root / 'merged'
        merged.mkdir()
        for path in self.files:
            shutil.copyfile(path, merged / path.name)
        # actions/download-artifact merge-multiple:true erases directory identities;
        # identical APK names overwrite one architecture before the old loop runs.
        self.assertEqual(len(list(merged.glob('*.apk'))), 1)
        old = subprocess.run(['bash', '-c',
                             'shopt -s nullglob; count=0; for dir in "$1"/packages-*; do '
                             'for file in "$dir"/aether-xray_*.ipk "$dir"/aether-xray-*.apk; '
                             'do count=$((count+1)); done; done; echo "$count"; [ "$count" -gt 0 ]',
                             'old-collector', str(merged)], capture_output=True, text=True)
        self.assertEqual(old.returncode, 1)
        self.assertEqual(old.stdout.strip(), '0')
        print('OLD EVIDENCE merge=true: 4 inputs -> 3 files (1 APK overwritten); old loop -> 0 packages, exit 1')

    def test_workflow_wires_production_entry_and_guard(self):
        workflow = (ROOT / '.github/workflows/release-component.yml').read_text()
        self.assertIn('merge-multiple: false', workflow)
        self.assertIn('python3 tools/release/collect_component.py', workflow)
        self.assertIn('--component "$COMPONENT" --version "$VERSION"', workflow)
        self.assertIn('sha256sum --check SHA256SUMS', workflow)
        self.assertLess(workflow.index('python3 tools/release/collect_component.py'),
                        workflow.index('gh release create'))
        self.assertLess(workflow.index('gh release view "$tag"'), workflow.index('gh release create'))
        self.assertIn('release $tag already exists', workflow)


if __name__ == '__main__':
    unittest.main(verbosity=2)
