#!/usr/bin/env python3
"""Check SDK-produced ChinaDNS-NG ipks (aarch64_generic and x86_64)."""
import hashlib
import io
from pathlib import Path
import struct
import subprocess
import sys
import tarfile
import tempfile

EXPECTED = {
    'aarch64_generic': (183, '42ddd494200ec6d88b35902927688d316bc23e06e6c08d9e01eb2412196ab845'),
    'x86_64': (62, '842ea4e9816efd91d39bc76ead5c4a42e79011757e37c521b4270b675cfcb30c'),
}


def check(path):
    with tarfile.open(path, 'r:gz') as package:
        with tarfile.open(fileobj=io.BytesIO(package.extractfile('./control.tar.gz').read()), mode='r:gz') as control:
            fields = dict(line.split(': ', 1) for line in control.extractfile('./control').read().decode().splitlines() if ': ' in line)
        assert fields['Package'] == 'chinadns-ng', fields
        assert fields['Version'] == '2025.08.09-r1', fields
        arch = fields['Architecture']
        machine, digest = EXPECTED[arch]
        with tarfile.open(fileobj=io.BytesIO(package.extractfile('./data.tar.gz').read()), mode='r:gz') as data:
            files = [m for m in data.getmembers() if not m.isdir()]
            assert len(files) == 1 and files[0].name.removeprefix('./') == 'usr/bin/chinadns-ng', files
            assert files[0].isfile() and files[0].mode & 0o111
            binary = data.extractfile(files[0]).read()
    assert binary[:6] == b'\x7fELF\x02\x01', 'not ELF64 little-endian'
    assert struct.unpack_from('<H', binary, 18)[0] == machine, 'wrong ELF machine'
    assert hashlib.sha256(binary).hexdigest() == digest, 'not the pinned upstream binary'
    if arch == 'x86_64':
        with tempfile.TemporaryDirectory() as tmp:
            executable = Path(tmp) / 'chinadns-ng'
            executable.write_bytes(binary)
            executable.chmod(0o755)
            result = subprocess.run([str(executable), '-V'], capture_output=True, text=True, check=True)
            assert (result.stdout + result.stderr).splitlines()[0].split()[1] == '2025.08.09'
    print(f'PASS {path}: {arch}, ELF machine {machine}, /usr/bin/chinadns-ng only, SHA256 {digest}')
    return arch


if __name__ == '__main__':
    assert len(sys.argv) == 3, 'usage: check_chinadns_packages.py <aarch64.ipk> <x86_64.ipk>'
    assert {check(Path(p)) for p in sys.argv[1:]} == set(EXPECTED)
