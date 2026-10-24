#!/usr/bin/env python3
"""T9.34 status CLI: isolated UCI files, sys-root and shared command substitutes."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
STUBS = ROOT / 'tests/stubs/bin'
PLUGINS = {
    'ssr-plus': ('shadowsocksr', "config global\n option global_server 'node1'\n"),
    'passwall': ('passwall', "config global\n option enabled '1'\n"),
    'passwall2': ('passwall2', "config global\n option enabled '1'\n"),
    'homeproxy': ('homeproxy', "config homeproxy 'config'\n option main_node 'node1'\n"),
    'openclash': ('openclash', "config openclash 'config'\n option enable '1'\n"),
    'nikki': ('nikki', "config nikki 'config'\n option enabled '1'\n"),
}
passed = 0
with tempfile.TemporaryDirectory(prefix='aether-status-conflicts-') as temp:
    t = Path(temp)
    conf, run, sysroot, binary = (t / name for name in ('conf', 'run', 'sys', 'bin'))
    for directory in (conf, run, binary, sysroot / 'etc/init.d'):
        directory.mkdir(parents=True)
    sample = (ROOT / 'tests/fixtures/sample/aetherproxy').read_text()
    (conf / 'aetherproxy').write_text(sample)
    (run / 'state.json').write_text('{"state":"stopped"}\n')
    # Existing events must stay byte-for-byte unchanged, not just absent for a new run.
    (run / 'events.jsonl').write_text('{"sentinel":true}\n')
    (sysroot / 'var/etc').mkdir(parents=True)
    (sysroot / 'tmp/dnsmasq.d').mkdir(parents=True)
    (sysroot / 'var/etc/dnsmasq.conf.test').write_text('interface=br-lan\nconf-dir=/tmp/dnsmasq.d\n')
    for name in ('common.sh', 'nft', 'killall'):
        shutil.copyfile(STUBS / name, binary / name)
        (binary / name).chmod(0o755)
    for name in ('xray', 'chinadns-ng'):
        (binary / name).write_text('#!/bin/sh\nexit 0\n')
        (binary / name).chmod(0o755)
    env = dict(os.environ, STUB_LOG=str(t / 'calls'))
    command = [str(ROOT / 'tests/host/ucode'), '-S', str(ROOT / 'aether-proxy/src/aether-proxy'),
               '--', 'status', '--json', '--confdir', str(conf), '--run-dir', str(run),
               '--sys-root', str(sysroot), '--bin-dir', str(binary)]

    def reset(plugin='ssr-plus', content=None, boot=False, installed=True, enabled=True,
              tables='', chains='', process='', tables_rc=0, chains_rc=0):
        for directory in (conf, sysroot / 'etc/init.d'):
            for path in directory.iterdir():
                path.unlink()
        (conf / 'aetherproxy').write_text(sample if enabled else sample.replace("option enabled '1'", "option enabled '0'", 1))
        init, default = PLUGINS[plugin]
        if content is not None:
            (conf / init).write_text(default if content is True else content)
        if installed:
            path = sysroot / 'etc/init.d' / init
            shutil.copyfile(STUBS / 'plugin-init', path)
            path.chmod(0o755)
            if boot:
                Path(str(path) + '.boot').touch()
        for name, value in (('tables', tables), ('chains', chains), ('process', process)):
            (t / name).write_text(value)
        (t / 'stub.env').write_text(
            f"STUB_LOG='{t}/calls'\nSTUB_NFT_TABLES_FILE='{t}/tables'\n"
            f"STUB_NFT_CHAINS_FILE='{t}/chains'\nSTUB_PROCESSES_FILE='{t}/process'\n"
            f"STUB_NFT_TABLES_RC={tables_rc}\nSTUB_NFT_CHAINS_RC={chains_rc}\n")
        (t / 'calls').write_text('')

    def check(label, expected):
        global passed
        protected = [*conf.iterdir(), run / 'state.json', run / 'events.jsonl']
        before = {path: path.read_bytes() for path in protected}
        result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=15)
        assert result.returncode == 0 and result.stderr == '', (label, result.returncode, result.stderr, result.stdout)
        data = json.loads(result.stdout)
        assert data['notices'] == expected, (label, data['notices'], expected)
        assert before == {path: path.read_bytes() for path in protected}, (label, 'status changed protected files')
        assert not list(conf.glob('.*')), (label, 'unexpected UCI delta')
        calls = (t / 'calls').read_text().splitlines()
        for line in calls:
            assert line.startswith(('nft list ', 'killall -0 ', 'init ')), (label, 'unexpected mutating command', line)
        if expected:
            assert calls.count('nft list tables') == calls.count('nft list chains inet fw4') == 1, calls
            assert calls.count('killall -0 clash') == calls.count('killall -0 mihomo') == 1, calls
        passed += 1
        print('PASS  T9.34 status ' + label)
        return calls

    def notice(plugin='ssr-plus', boot=False, configured=False):
        return [{'code': 'CONFLICT_ENABLED', 'args': {'plugin': plugin, 'boot': boot, 'configured': configured}}]

    reset(content="config global\n option global_server 'nil'\n", boot=True)
    check('ssr-plus nil plus boot', notice(boot=True))
    reset(content=True)
    check('ssr-plus node without boot', notice(configured=True))
    reset(content=True, boot=True)
    check('ssr-plus node plus boot is one notice', notice(boot=True, configured=True))
    reset(content="config global\n option global_server 'nil'\n")
    check('both disabled', [])
    reset(content=True, enabled=False, boot=True)
    assert check('main disabled', []) == []
    reset(content=True, installed=False, boot=True)
    assert not any(line.startswith('init ') for line in check('init absent', []))
    reset(content=True, boot=True, tables='table inet ss_spec\ntable ip ss_spec_mangle\n')
    assert not any(line.startswith('init ') for line in check('running suppresses notice', []))
    for plugin in PLUGINS:
        reset(plugin, content=True)
        check(plugin + ' configured', notice(plugin, configured=True))
        reset(plugin, boot=True)
        check(plugin + ' missing package still boot enabled', notice(plugin, boot=True))
    reset('homeproxy', content="config homeproxy 'config'\n option main_node 'nil'\nconfig server 'server'\n option enabled '1'\n")
    check('homeproxy server alternative', notice('homeproxy', configured=True))
    reset('homeproxy', content="config homeproxy 'config'\n option main_node 'nil'\nconfig server 'server'\n option enabled '0'\n")
    check('homeproxy both alternatives disabled', [])
    for plugin in ('passwall', 'passwall2'):
        reset(plugin, content="config global\n option enabled '0'\nconfig global\n option enabled '1'\n")
        check(plugin + ' only first global matters', [])
    for plugin in ('openclash', 'nikki'):
        reset(plugin, content=True, process=('clash' if plugin == 'openclash' else 'mihomo') + '\n')
        check(plugin + ' process suppresses notice', [])
    reset('homeproxy', content=True, chains='table inet fw4 {\n chain homeproxy_test {\n }\n}\n')
    check('homeproxy chain suppresses notice', [])
    reset(content="not valid uci {\n", boot=True)
    check('unreadable foreign package is not configured', notice(boot=True))
    reset(content=True, chains_rc=1)
    check('missing fw4 is harmless', notice(configured=True))
    reset(content=True, tables_rc=2)
    check('runtime inspection failure is quiet and suppresses notice TODO(design)', [])
print(f'{passed} passed, 0 failed')
