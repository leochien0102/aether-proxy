#!/usr/bin/env python3
"""Four required negative controls; restore exact bytes even when a control fails."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
DNS = ROOT / 'aether-proxy/src/lib/bootstrap_dns.uc'
APPLY = ROOT / 'aether-proxy/src/lib/apply.uc'

CONTROLS = [
    (DNS, 'if (rr.owner != name)', 'if (false)', 'Q6', 'Q6 associated cname'),
    (DNS, 'response = exchange(s, endpoint, domain, entropy.id, true);',
     's.deadline = now_ms() + C.BOOTSTRAP_DNS_TIMEOUT_MS;\n'
     '\t\t\tresponse = exchange(s, endpoint, domain, entropy.id, true);',
     'Q5', 'Q5 UDP TCP share original deadline'),
    (APPLY, 'let valid = bootstrap_dns.validate(address, endpoint);',
     "let cached = read_lkg(ctx)[address];\n"
     "\tif (cached != null) return result('wrong cache-first', { ip: cached, source: 'lkg' });\n"
     '\tlet valid = bootstrap_dns.validate(address, endpoint);', 'Q8', 'Q8 DNS precedes warm LKG'),
    (APPLY, 'if (resolved.cancelled)\n\t\t\treturn resolved;',
     'if (resolved.cancelled)\n\t\t\tcontinue;', 'Q9',
     'Q9 real SIGTERM cancel-udp no retry write fallback'),
]

for path, old, new, group, assertion in CONTROLS:
    original = path.read_bytes()
    source = original.decode()
    assert source.count(old) == 1, (path, old)
    try:
        path.write_text(source.replace(old, new))
        result = subprocess.run(['bash', 'tests/bootstrap-dns/run.sh', group], cwd=ROOT,
                                text=True, capture_output=True, timeout=40)
        combined = result.stdout + result.stderr
        # A timed-out server, syntax error, or unrelated exception does not prove the assertion.
        assert result.returncode == 1 and 'AssertionError: ' + assertion in combined, combined
        print(f'PASS  negative control {group}: AssertionError: {assertion}', flush=True)
    finally:
        path.write_bytes(original)

print('PASS  four negative controls restored exact implementation bytes', flush=True)
