#!/usr/bin/env python3
"""Archive-level usage keep.d regression: unmodified OpenWrt 24.10.8 sysupgrade -b.

Requires Linux x86_64 unprivileged user/mount namespaces, curl, and an
actual SDK-built IPK. Writes only beneath --work (default: this tree's .cache).
No firmware image, flash command, package install or host root modifications.
"""
import argparse
import hashlib
import io
from pathlib import Path
import shutil
import subprocess
import tarfile

REPO = Path(__file__).resolve().parents[2]
BASE = 'https://raw.githubusercontent.com/openwrt/openwrt/v24.10.8/package/base-files/files/'
SOURCES = {
    'sbin/sysupgrade': ('sysupgrade', '227db731326313bd43553645523874f308a381f8593e20a03081f9cdfb1fca18'),
    'lib/functions.sh': ('functions.sh', '0a834605bca24da7d31e15f6f37767290d12f95b1cdb5804f797684b329f66dc'),
    'lib/functions/system.sh': ('system.sh', '0ce625f050e6101696d0c75a33d32ba9f41375b6d88e53113b5e675ccee19859'),
    'lib/upgrade/common.sh': ('common.sh', 'c33b304881f13b55684e41d852835f885798fe752a1c075c6b9588b6174af16d'),
    'lib/upgrade/tar.sh': ('tar.sh', '3a81842277098e345af53932354abf7e30ab86dafb8887bb3b113c6e64c9e6fe'),
    'usr/share/libubox/jshn.sh': ('jshn.sh', 'd392055502cf3bf74d4a733b454ca0beff9374e167732a0b831df96413beafb8'),
}
JSHN = 'https://raw.githubusercontent.com/openwrt/libubox/49056d178f42da98048a5d4c23f83a6f6bc6dd80/sh/jshn.sh'
ROOTFS_URL = 'https://downloads.openwrt.org/releases/24.10.8/targets/x86/64/openwrt-24.10.8-x86-64-rootfs.tar.gz'
ROOTFS_SHA = '6c94190246a54088e3984fc0c4cbbb518972abb2b10a28e30a0c41554eea8b9d'
LEDGER = (b'{"schema":1,"updated_at":1795392000,"days":{"2026-11-22":{"tx":8388609,'
          b'"rx":123456789,"observed":86400,"healthy":86399}},'
          b'"quota":{"bytes":1073741824,"set_at":1795305600}}\n')
MEMBER = 'etc/aether-proxy/usage.json'
KEEP = 'lib/upgrade/keep.d/aether-proxy'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def run(argv):
    result = subprocess.run([str(x) for x in argv], text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f'{argv}: exit {result.returncode}\n{result.stdout}')
    return result.stdout


def write(root, name, data):
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return path


def recover(backup):
    members = backup.getnames()
    assert members.count(MEMBER) == 1, f'missing or duplicate {MEMBER}: {members}'
    recovered = backup.extractfile(MEMBER).read()
    assert recovered == LEDGER, 'archive bytes differ from original'
    return recovered


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ipk', type=Path, required=True)
    parser.add_argument('--work', type=Path, default=REPO / '.cache/T16.49/archive-test')
    parser.add_argument('--rootfs-tar', type=Path,
                        help='official OpenWrt 24.10.8 x86_64 rootfs tar (downloaded if omitted)')
    args = parser.parse_args()
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    # Never extract an IPK over the rootfs: only read the precise keep.d member.
    with tarfile.open(args.ipk, 'r:*') as package:
        data = next(m for m in package if m.name.removeprefix('./') == 'data.tar.gz')
        with tarfile.open(fileobj=io.BytesIO(package.extractfile(data).read()), mode='r:gz') as payload:
            files = {m.name.removeprefix('./'): m for m in payload}
            assert files[KEEP].isfile()
            keep = payload.extractfile(files[KEEP]).read()
            assert keep == b'/etc/aether-proxy/usage.json\n', keep
            assert MEMBER not in files, 'package must not ship a ledger'
    print(f'PASS actual IPK {args.ipk.resolve()} sha256={sha(args.ipk.read_bytes())}')
    print(f'PASS /{KEEP}: {keep!r}; no packaged ledger')
    sources = work / 'sources'
    sources.mkdir(exist_ok=True)
    for dest, (name, digest) in SOURCES.items():
        path = sources / name
        if not path.exists():
            run(['curl', '-fsSL', JSHN if name == 'jshn.sh' else BASE + dest, '-o', path])
        assert sha(path.read_bytes()) == digest, f'source hash mismatch: {path}'
        print(f'PASS source {dest} sha256={digest}')
    runtime = args.rootfs_tar or sources / 'openwrt-24.10.8-x86-64-rootfs.tar.gz'
    if not runtime.exists():
        run(['curl', '-fsSL', ROOTFS_URL, '-o', runtime])
    assert sha(runtime.read_bytes()) == ROOTFS_SHA, 'official rootfs hash mismatch'
    print(f'PASS official runtime rootfs sha256={ROOTFS_SHA}')
    with tarfile.open(runtime, 'r:gz') as archive:
        binaries = {name: archive.extractfile('./' + name).read()
                    for name in ['bin/busybox', 'lib/libc.so', 'lib/libgcc_s.so.1']}
    for variant, entry in [('fixed', keep), ('old-relative', keep.lstrip(b'/'))]:
        root = work / variant
        if root.exists():
            shutil.rmtree(root)
        root.mkdir()
        for dest, (name, _) in SOURCES.items():
            write(root, dest, (sources / name).read_bytes())
        for directory in ['bin', 'root', 'tmp', 'proc', 'etc/init.d']:
            (root / directory).mkdir(parents=True, exist_ok=True)
        # Copy only runtime binaries, never the distribution's keep.d/conffiles.
        for name, data in binaries.items():
            write(root, name, data).chmod(0o755)
        (root / 'lib/ld-musl-x86_64.so.1').symlink_to('libc.so')
        (root / 'bin/sh').symlink_to('busybox')
        # Minimal non-device files: dd needs <=512 bytes of zeros for tar headers.
        write(root, 'dev/zero', bytes(4096))
        write(root, 'dev/null', b'')
        write(root, 'proc/mounts', b'')  # no ramdisk root in this sparse rootfs
        # Keep the old /root negative control archive nonempty, so it exercises
        # the same member/byte assertion instead of failing tar's empty-input check.
        write(root, 'etc/sysupgrade.conf', b'/etc/config/backup-sentinel\n')
        write(root, 'etc/config/backup-sentinel', b'unrelated configuration\n')
        write(root, 'usr/lib/opkg/status', b'')  # no changed package conffiles
        write(root, KEEP, entry)
        ledger = write(root, MEMBER, LEDGER)
        # No other keep.d entries or overlay scan; the sole sysupgrade.conf
        # entry is a specific unrelated file, never a ledger parent directory.
        assert list((root / 'lib/upgrade/keep.d').iterdir()) == [root / KEEP]
        sandbox = ['unshare', '--user', '--map-root-user', '--mount', 'chroot', root]
        # OpenWrt disables BusyBox --install; provide its normal applet symlinks.
        for applet in ['ash', 'awk', 'cat', 'date', 'dd', 'find', 'gzip', 'hexdump',
                       'logger', 'ls', 'mount', 'rm', 'sed', 'sort', 'tar', 'tr', 'vi']:
            (root / 'bin' / applet).symlink_to('busybox')
        for cwd, label in [('/', 'slash'), ('/root', 'root')]:
            archive = f'/tmp/{label}.tgz'
            # cd only to the requested cwd; sysupgrade itself is byte-for-byte upstream.
            output = run(sandbox + ['/bin/sh', '-c',
                         'cd "$1" && exec /bin/sh /sbin/sysupgrade -b "$2"',
                         'usage-backup', cwd, archive])
            (work / f'{variant}-{label}.log').write_text(output)
            with tarfile.open(root / archive.lstrip('/'), 'r:gz') as backup:
                members = backup.getnames()
                if variant == 'old-relative' and cwd == '/root':
                    try:
                        recover(backup)  # exactly the positive-case roundtrip assertion
                    except AssertionError as error:
                        assert MEMBER not in members, members
                        print(f'PASS negative control cwd={cwd}: roundtrip assertion FAILED as expected: {error}')
                    else:
                        raise AssertionError('old relative entry unexpectedly passed /root roundtrip')
                else:
                    recovered = recover(backup)
                    write(work, f'{variant}-{label}.recovered.json', recovered)
                    print(f'PASS {variant} cwd={cwd}: member={MEMBER} bytes={len(recovered)} '
                          f'sha256={sha(recovered)} byte_equal=true')
            assert ledger.read_bytes() == LEDGER, 'backup mutated original ledger'
            print(f'ARCHIVE {root / archive.lstrip("/")} members={members}')
    print('usage-backup: fixed 2/2 byte roundtrips; old relative / passes, /root regression detected')


if __name__ == '__main__':
    main()
