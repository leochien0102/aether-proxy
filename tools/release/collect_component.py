#!/usr/bin/env python3
"""Fail-closed collector for release-component (not the application's release chain)."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import struct
import sys
import tarfile
import tempfile
import zlib

COMPONENTS = {'aether-xray': 'xray', 'aether-dns': 'dns', 'chinadns-ng': 'chinadns-ng'}
SLOTS = tuple((sdk, arch, fmt) for sdk, fmt in
              [('24.10.8', 'ipk'), ('25.12.5', 'apk')]
              for arch in ['x86_64', 'aarch64_generic'])


def require(condition, message):
    if not condition:
        raise ValueError(message)


def ipk_metadata(data):
    # OpenWrt ipkg-build uses a tar envelope (not Debian's ar envelope).
    def member(archive, name):
        matches = [m for m in archive.getmembers() if m.name.removeprefix('./') == name]
        require(len(matches) == 1 and matches[0].isfile(), f'IPK missing/duplicate {name}')
        return archive.extractfile(matches[0]).read()

    with tarfile.open(fileobj=io.BytesIO(data), mode='r:*') as outer:
        require(member(outer, 'debian-binary') == b'2.0\n', 'invalid IPK envelope')
        control = member(outer, 'control.tar.gz')
        member(outer, 'data.tar.gz')
    with tarfile.open(fileobj=io.BytesIO(control), mode='r:gz') as archive:
        text = member(archive, 'control').decode('utf-8')
    fields = {}
    for line in text.splitlines():
        if line.startswith((' ', '\t')) or not line:
            continue
        key, sep, value = line.partition(':')
        require(sep and key not in fields, 'invalid/duplicate IPK control field')
        fields[key] = value.strip()
    return tuple(fields[key] for key in ('Package', 'Version', 'Architecture'))


def apk_metadata(data):
    """Read APK v3 ADB package identity; no filename-based identity fallback."""
    if data[:4] == b'ADBd':
        decoder = zlib.decompressobj(-15)
        data = decoder.decompress(data[4:]) + decoder.flush()
        require(decoder.eof and not decoder.unused_data, 'invalid APK deflate stream')
    require(data[:8] == b'ADB.pckg', 'expected APK v3 package schema')
    # ADB block and schema readers below deliberately support only the producer's
    # v3 package metadata; unknown types/compression fail closed.
    return adb_identity(data)


def adb_identity(data):
    # apk-tools 3.0.5, commit b5a31c0d865342ad80be10d68f1bb3d3ad9b0866:
    # src/adb.h (blocks, typed offsets), src/adb.c (adb_r_obj/blob),
    # src/apk_adb.h (PKG_PKGINFO=1; PI_NAME=1, VERSION=2, ARCH=5).
    position = 8
    database = None
    while position < len(data):
        require(position + 4 <= len(data), 'truncated APK block')
        header = struct.unpack_from('<I', data, position)[0]
        kind, size, header_size = header >> 30, header & 0x3fffffff, 4
        if kind == 3:
            require(position + 16 <= len(data), 'truncated APK extended block')
            kind, size, header_size = header & 0x3fffffff, struct.unpack_from('<Q', data, position + 8)[0], 16
        require(kind in (0, 1, 2) and header_size <= size <= len(data) - position,
                'invalid APK block size/type')
        if database is None:
            require(kind == 0, 'APK must start with metadata block')
            database = data[position + header_size:position + size]
        else:
            require(kind != 0, 'duplicate APK metadata block')
        position += (size + 7) & ~7
        require(position <= len(data), 'truncated APK block padding')
    require(database is not None and len(database) >= 8 and database[:4] == bytes(4),
            'unsupported APK ADB version')

    def word(offset):
        require(0 <= offset <= len(database) - 4, 'APK offset out of bounds')
        return struct.unpack_from('<I', database, offset)[0]

    def field(value, index):
        require(value >> 28 == 14, 'expected APK object')
        offset = value & 0x0fffffff
        count = word(offset)
        require(offset % 4 == 0 and index < count <= (len(database) - offset) // 4,
                'invalid APK object bounds')
        return word(offset + index * 4)

    def blob(value):
        width = {8: 1, 9: 2, 10: 4}.get(value >> 28)
        require(width is not None, 'expected APK string blob')
        offset = value & 0x0fffffff
        require(8 <= offset <= len(database) - width, 'APK blob offset out of bounds')
        length = int.from_bytes(database[offset:offset + width], 'little')
        start = offset + width
        require(0 < length <= len(database) - start, 'invalid APK blob bounds')
        return database[start:start + length].decode('utf-8')

    info = field(word(4), 1)
    return tuple(blob(field(info, index)) for index in (1, 2, 5))


def metadata(data, fmt):
    return ipk_metadata(data) if fmt == 'ipk' else apk_metadata(data)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def collect(artifacts, output, component, version):
    require(component in COMPONENTS, f'unsupported component {component}')
    require(re.fullmatch(r'[0-9][0-9A-Za-z.+~-]*-r[0-9]+', version), 'invalid version')
    require(not output.exists() and not output.is_symlink(), f'output already exists: {output}')
    expected_dirs = {f'packages-{sdk}-{arch}' for sdk, arch, _ in SLOTS}
    actual_dirs = {p.name for p in artifacts.glob('packages-*')}
    require(actual_dirs == expected_dirs,
            f'artifact slots: expected {sorted(expected_dirs)}, actual {sorted(actual_dirs)}')
    planned = []
    names = set()
    for sdk, arch, fmt in SLOTS:
        directory = artifacts / f'packages-{sdk}-{arch}'
        require(directory.is_dir() and not directory.is_symlink(), f'invalid slot {directory}')
        packages = sorted(p for p in directory.rglob('*') if p.suffix in ('.ipk', '.apk'))
        # A component-only build uploads packages plus index files; another package
        # is never silently ignored on the basis of a misleading filename.
        require(len(packages) == 1, f'{directory.name}: expected exactly one package, got {len(packages)}')
        source = packages[0]
        require(source.parent == directory and source.is_file() and not source.is_symlink(),
                f'package is not a regular artifact-root file: {source}')
        require(source.suffix == '.' + fmt, f'{directory.name}: wrong format {source.name}, expected {fmt}')
        data = source.read_bytes()
        identity = metadata(data, fmt)
        want = (component, version, arch)
        require(identity == want, f'{directory.name}: expected metadata {want}, actual {identity}')
        name = source.name
        if fmt == 'apk' and not name.endswith(f'_{arch}.apk'):
            name = name[:-4] + f'_{arch}.apk'
        require(name not in names, f'output name collision: {name}')
        names.add(name)
        canonical = (f'{component}_{version}_{arch}.ipk' if fmt == 'ipk'
                     else f'{component}-{version}_{arch}.apk')
        planned.append((name, canonical, data, directory.name, identity))
    # Check all collisions before enforcing spelling, and all names before staging.
    for name, canonical, *_ in planned:
        require(name == canonical, f'invalid output name: {name}, expected {canonical}')
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=f'.{output.name}-', dir=output.parent))
    try:
        checksums = []
        for name, _, data, slot, identity in planned:
            (stage / name).write_bytes(data)
            checksums.append(f'{digest(data)}  {name}\n')
            print(json.dumps({'slot': slot, 'metadata': identity, 'asset': name, 'sha256': digest(data)}))
        (stage / 'SHA256SUMS').write_text(''.join(sorted(checksums)), encoding='utf-8')
        # Re-read every staged byte via the manifest, rather than just hashing inputs.
        for line in (stage / 'SHA256SUMS').read_text().splitlines():
            checksum, name = line.split('  ', 1)
            require(digest((stage / name).read_bytes()) == checksum, f'checksum mismatch: {name}')
        require(not output.exists() and not output.is_symlink(), f'output appeared: {output}')
        os.rename(stage, output)
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifacts', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--component', required=True, choices=COMPONENTS)
    parser.add_argument('--version', required=True)
    args = parser.parse_args()
    try:
        collect(args.artifacts, args.output, args.component, args.version)
    except (ValueError, KeyError, OSError, tarfile.TarError, UnicodeError, zlib.error, struct.error) as exc:
        print(f'::error::component assets: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
