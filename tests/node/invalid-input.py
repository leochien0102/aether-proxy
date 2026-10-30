#!/usr/bin/env python3
"""T9.41 B-F1: reject each class at CLI parse/import and cold configuration read."""
import os
from pathlib import Path
import json
import subprocess
import sys

ROOT, T = map(Path, sys.argv[1:3])
CONF, RUN = T / 'etc/config', T / 'run'
CONF.mkdir(parents=True, exist_ok=True)
RUN.mkdir(parents=True, exist_ok=True)
CONFIG = CONF / 'aetherproxy'
NODE = 'n_' + '1' * 32
BASE = f"config main 'main'\n option enabled '1'\n option node '{NODE}'\n"
BASE += f"config node '{NODE}'\n option protocol 'vless'\n option uuid 'id'\n"
BASE += " option address 'edge.example'\n option port '443'\n option security 'tls'\n"
CASES = [
    ('fingerprint', 'fp=bogus', " option fingerprint 'bogus'\n"),
    ('encryption', 'encryption=bogus', " option encryption 'bogus'\n"),
    ('xhttp_mode', 'type=xhttp&mode=bogus', " option transport 'xhttp'\n option xhttp_mode 'bogus'\n"),
    ('password', None, " option protocol 'shadowsocks'\n option method '2022-blake3-aes-128-gcm'\n option password 'pw'\n"),
]


def ap(*args):
    p = subprocess.run([str(ROOT / 'tests/host/ucode'), '-S', str(ROOT / 'aether-proxy/src/aether-proxy'),
                        '--', *args, '--json', '--confdir', str(CONF), '--run-dir', str(RUN)],
                       cwd=ROOT, env=os.environ, text=True, capture_output=True)
    assert p.stderr == '', p.stderr
    return p, json.loads(p.stdout)


for field, query, options in CASES:
    CONFIG.write_text(BASE)
    before = CONFIG.read_bytes()
    uri = ('vless://id@edge.example:443?security=tls&' + query if query is not None
           else 'ss://2022-blake3-aes-128-gcm:pw@edge.example:443')
    for command in ['parse', 'import']:
        p, r = ap('node', command, uri)
        assert p.returncode == 2 and r['code'] == 'CONFIG_INVALID' and r['detail'] == 'invalid_value', (field, r)
        assert CONFIG.read_bytes() == before
        print(f'PASS  T9.41 CLI {command} rejects {field} invalid_value without writing UCI')
    CONFIG.write_text(BASE + options)
    p, r = ap('check', '--no-precheck')
    assert p.returncode != 0 and r['code'] == 'CONFIG_INVALID', (field, r)
    assert any(e['field'] == f'node.{NODE}.{field}' and e['code'] == 'invalid_value' for e in r['errors']), r
    assert not [p for p in RUN.iterdir() if p.name != 'events.jsonl'], list(RUN.iterdir())
    print(f'PASS  T9.41 cold config read rejects {field} before writing artifacts')
