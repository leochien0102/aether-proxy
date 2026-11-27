#!/usr/bin/env python3
"""DSH-only Linux host probe; never installs packages or contacts a device.

Usage: python3 tests/t16.119/bytecode-probe.py --ucode /absolute/path/to/ucode --source-root /r4/checkout
Use a binary (or wrapper) whose fs, uci and log native modules are available.
This measures held source fds, NOT F_GETFD, rpcd reloads or upgrade safety.
"""
import argparse
import json
import os
from pathlib import Path
import select
import shutil
import stat
import subprocess
import tempfile


LOADER = """
import * as fs from 'fs';
let entry = loadfile(ARGV[0]);
assert(type(entry) == 'function', 'loadfile failed');
let plugin = entry();
assert(type(plugin.aetherproxy.version.call) == 'function', 'plugin shape');
print('READY\\n');
fs.stdout.flush();
fs.stdin.read('line');
assert(type(plugin.aetherproxy.version.call) == 'function', 'closure lost');
"""


def snapshot(pid, stage):
    rows = []
    proc = Path('/proc') / str(pid)
    for fd in sorted((proc / 'fd').iterdir(), key=lambda p: int(p.name)):
        target = os.readlink(fd)
        info = (proc / 'fdinfo' / fd.name).read_text()
        meta = fd.stat()
        rows.append({
            'fd': int(fd.name), 'target': target,
            'ours': target.startswith(str(stage) + '/'),
            'deleted': target.endswith(' (deleted)'),
            'regular': stat.S_ISREG(meta.st_mode),
            'dev': meta.st_dev, 'inode': meta.st_ino,
            'fdinfo': info,
        })
    return {'fds': rows, 'limits': (proc / 'limits').read_text()}


def observe(ucode, path, modules, stage):
    command = [ucode, '-L', str(modules / '*.uc'), '-e', LOADER, '--', str(path)]
    child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True)
    try:
        ready, _, _ = select.select([child.stdout], [], [], 20)
        if not ready or child.stdout.readline() != 'READY\n':
            child.kill()
            out, err = child.communicate()
            raise RuntimeError(f'loader failed or timed out: {out}\n{err}')
        result = snapshot(child.pid, stage)
        out, err = child.communicate('\n', timeout=10)
        if child.returncode:
            raise RuntimeError(f'loader exit {child.returncode}: {out}\n{err}')
        result['stderr'] = err
        return result
    finally:
        if child.poll() is None:
            child.kill()
            child.communicate()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ucode', required=True)
    parser.add_argument('--source-root', type=Path, required=True, help='pre-guard checkout to probe')
    args = parser.parse_args()
    ucode = str(Path(args.ucode).resolve())
    with tempfile.TemporaryDirectory(prefix='aether-t16.119-') as tmp:
        stage = Path(tmp)
        modules = stage / 'modules'
        modules.mkdir()
        shutil.copytree(args.source_root / 'aether-proxy/src/lib', modules / 'aetherproxy')
        source = stage / 'aetherproxy.uc'
        shutil.copyfile(args.source_root / 'luci-app-aether-proxy/root/usr/share/rpcd/ucode/aetherproxy.uc', source)
        artifacts = {}
        for kind, flags in [('debug', []), ('stripped', ['-s'])]:
            artifact = stage / f'{kind}.uc'
            subprocess.run([ucode, '-L', str(modules / '*.uc'),
                            '-cno-interp,dynlink=fs,dynlink=uci,dynlink=log',
                            *flags, '-o', str(artifact), str(source)],
                           check=True, timeout=30)
            artifacts[kind] = artifact
        results = {'ucode': ucode}
        for kind, path in [('source', source), *artifacts.items()]:
            results[kind] = observe(ucode, path, modules, stage)
        # A positive hidden-source run proves the static import closure is in
        # the artifact, rather than silently loaded from this staged source tree.
        modules.rename(stage / 'hidden-modules')
        source.rename(stage / 'hidden-entry.uc')
        results['stripped_hidden_sources'] = observe(
            ucode, artifacts['stripped'], modules, stage)
        print(json.dumps(results, indent=2))
        # Inspect observations instead of assuming every VM revision behaves alike.
        # The loader's explicit assertions check that the plugin remains callable.


if __name__ == '__main__':
    main()
