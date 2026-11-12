#!/usr/bin/env python3
"""M4-09 P7: three independent mutations; restore renderer even on failure."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
RENDERER = ROOT / 'aether-proxy/src/lib/render/nft.uc'
ORIGINAL = RENDERER.read_text()
TCP = 'push(out, `${T}${T}meta l4proto tcp tcp dport { ${tcp_ports(main)} } jump host_policy`);'
UDP = 'push(out, `${T}${T}meta l4proto udp jump host_policy`);'
ALL = 'push(out, `${T}${T}jump host_policy`);'
MUTATIONS = [
    ('remove TCP port condition', TCP, ALL, 'FAIL  m409-common/aether-proxy.nft'),
    ('filter UDP ports too', UDP,
     'push(out, `${T}${T}meta l4proto udp udp dport { ${tcp_ports(main)} } jump host_policy`);',
     'FAIL  m409-common/aether-proxy.nft'),
    ('add condition to all', ALL, TCP, 'FAIL  m409-all/aether-proxy.nft'),
]

try:
    for name, before, after, expected in MUTATIONS:
        assert ORIGINAL.count(before) == 1, name
        RENDERER.write_text(ORIGINAL.replace(before, after))
        run = subprocess.run([str(ROOT / 'tests/host/ucode'), 'tests/run.uc'],
                             cwd=ROOT, text=True, capture_output=True)
        assert run.returncode != 0 and expected in run.stdout, (name, run.stdout, run.stderr)
        print(f'PASS  P7 mutation {name}: exit={run.returncode}; {expected}')
        for line in run.stdout.splitlines():
            if line.startswith('FAIL  unit/port_scope'):
                print('  ' + line)
        RENDERER.write_text(ORIGINAL)
finally:
    RENDERER.write_text(ORIGINAL)
