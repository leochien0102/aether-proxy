#!/usr/bin/env python3
"""Check locally built OpenWrt 24.10 ipks (no extraction to the filesystem).

Usage: python3 tests/package/aether-xray.py ARCH CORE.ipk [--application APP.ipk]
ARCH is aarch64_generic or x86_64. Fails on payload, ELF or dependency drift.
"""
import argparse
import hashlib
import io
from pathlib import Path
import struct
import tarfile


def unpack(path):
    with tarfile.open(path, "r:gz") as outer:
        blobs = {m.name.removeprefix("./"): outer.extractfile(m).read()
                 for m in outer if m.isfile()}
    assert blobs["debian-binary"] == b"2.0\n"
    with tarfile.open(fileobj=io.BytesIO(blobs["control.tar.gz"])) as control:
        text = next(control.extractfile(m).read().decode()
                    for m in control if m.name.removeprefix("./") == "control")
    fields = dict(line.split(": ", 1) for line in text.splitlines()
                  if line and not line.startswith(" ") and ": " in line)
    with tarfile.open(fileobj=io.BytesIO(blobs["data.tar.gz"])) as data:
        files = {m.name.removeprefix("./"): (m, data.extractfile(m).read())
                 for m in data if m.isfile()}
        # No symlinks/hardlinks or other non-directory payloads either.
        assert all(m.isdir() or m.isfile() for m in data)
    return fields, files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("arch", choices=["aarch64_generic", "x86_64"])
    parser.add_argument("core", type=Path)
    parser.add_argument("--application", type=Path)
    args = parser.parse_args()
    fields, files = unpack(args.core)
    assert fields["Package"] == "aether-xray", fields
    assert fields["Architecture"] == args.arch, fields
    assert fields["Version"] in ("26.10.29-r1", "26.10.29-1"), fields
    assert "ca-bundle" in fields["Depends"].split(", "), fields
    assert set(files) == {"usr/bin/aether-xray"}, files.keys()
    member, binary = files["usr/bin/aether-xray"]
    assert member.mode & 0o111, oct(member.mode)
    assert binary[:6] == b"\x7fELF\x02\x01", "not ELF64 little-endian"
    machine = struct.unpack_from("<H", binary, 18)[0]
    assert machine == {"aarch64_generic": 183, "x86_64": 62}[args.arch], machine
    # A static Go executable must not ask the loader for a dynamic interpreter.
    phoff = struct.unpack_from("<Q", binary, 32)[0]
    phsize, phnum = struct.unpack_from("<HH", binary, 54)
    assert all(struct.unpack_from("<I", binary, phoff + i * phsize)[0] != 3
               for i in range(phnum)), "unexpected PT_INTERP"
    print(f"PASS {args.core}: {fields['Version']} {args.arch}, "
          f"only usr/bin/aether-xray, ELF machine={machine}, static")
    print(f"  sha256={hashlib.sha256(args.core.read_bytes()).hexdigest()}")
    if args.application:
        app, payload = unpack(args.application)
        assert app["Package"] == "aether-proxy", app
        assert "aether-xray" in app["Depends"].split(", "), app
        assert "usr/bin/aether-xray" not in payload
        assert not any(blob.startswith(b"\x7fELF") for _, blob in payload.values())
        print(f"PASS {args.application}: Depends includes aether-xray; no ELF payload")
        print(f"  Depends: {app['Depends']}")


if __name__ == "__main__":
    main()
