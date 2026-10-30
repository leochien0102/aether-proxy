#!/usr/bin/env python3
"""T10.71: extend the existing real-daemon degradation fixture without changing it.

Only inject assertions into its two existing failure windows. The shipped monitor,
reload and state modules remain unmodified, including their normal persist_state.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
fixture = ROOT / 'tests/monitor/degrade.py'
source = fixture.read_text()

for marker, target in [('hash-fail', None), ('nft-load-fail', 'n_00000000000000000000000000000001')]:
    anchor = f"\t\t(f.root / '{marker}').unlink()"
    assert source.count(anchor) == 1, f'fixture anchor changed: {marker}'
    assertion = (
        "\t\trecord = f.state().get('last_reload', {})\n"
        f"\t\tassert record.get('ok') is False, ('T10.71 {marker} completion lost', f.state())\n"
        f"\t\tassert record.get('target_node') == {target!r}, record\n"
        "\t\tassert record.get('error') and record.get('at', 0) > 0, record\n"
        f"\t\tprint('PASS  T10.71 monitor {marker} failure completion survives persist_state', flush=True)\n"
    )
    source = source.replace(anchor, assertion + anchor)

exec(compile(source, str(fixture), 'exec'), {'__file__': str(fixture), '__name__': '__main__'})
