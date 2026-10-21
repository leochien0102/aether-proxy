#!/usr/bin/env python3
"""T9.10 docs/07: real CLI, one curl request, no daemon state/event mutations."""
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(sys.argv[1])
T = Path(sys.argv[2])
CONF = T / 'etc/config'
RUN = T / 'var/run/aether-proxy'
BIN = T / 'bin'
for directory in (CONF, RUN, BIN):
    directory.mkdir(parents=True, exist_ok=True)
CONFIG = CONF / 'aetherproxy'
CONFIG.write_text("config main 'main'\n option enabled '0'\nconfig probe 'probe'\n option timeout '2'\n")
CALLS = T / 'curl.log'
(BIN / 'curl').write_text('''#!/bin/sh
printf 'CALL\\n' >> "$URL_CURL_LOG"
printf '%s\\n' "$@" >> "$URL_CURL_LOG"
if [ -n "${URL_CURL_SLEEP:-}" ]; then sleep "$URL_CURL_SLEEP"; fi
printf '%s' "${URL_CURL_OUT:-204 0.123999}"
printf '%s' "${URL_CURL_ERR:-}" >&2
exit "${URL_CURL_RC:-0}"
''')
(BIN / 'curl').chmod(0o755)
EVENTS = RUN / 'events.jsonl'
EVENTS.write_text('existing event\n')
STATE = RUN / 'state.json'
SITES = [
    ('google', 'Google', 'https://www.gstatic.com/generate_204'),
    ('cloudflare', 'Cloudflare', 'https://cp.cloudflare.com/generate_204'),
    ('apple', 'Apple', 'https://captive.apple.com/hotspot-detect.html'),
    ('youtube', 'YouTube', 'https://www.youtube.com/generate_204'),
    ('github', 'GitHub', 'https://github.com/robots.txt'),
]


def check(name, condition):
    if not condition:
        raise AssertionError(name)
    print('PASS  ' + name)


def ap(*args, rc=0, env=None):
    CALLS.write_text('')
    before = {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in RUN.iterdir()}
    result = subprocess.run([
        str(ROOT / 'tests/host/ucode'), '-S', str(ROOT / 'aether-proxy/src/aether-proxy'), '--',
        'probe', *args, '--json', '--confdir', str(CONF), '--sys-root', str(T), '--bin-dir', str(BIN)
    ], text=True, capture_output=True, env={**os.environ, 'URL_CURL_LOG': str(CALLS), **(env or {})})
    assert result.returncode == rc, (args, result.returncode, result.stdout, result.stderr)
    assert result.stderr == '', result.stderr
    assert before == {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in RUN.iterdir()}, 'runtime files mutated'
    return json.loads(result.stdout)


STATE.write_text('{"state":"running","dns_tier":"T2","last_probe":{"ok":false},"other":[1,2]}\n')
reply = ap('sites')
check('probe sites: exact ordered table, google first, no curl',
      reply == dict(ok=True, sites=[dict(name=n, label=l, url=u) for n, l, u in SITES])
      and CALLS.read_text() == '')
for name, label, url in SITES:
    reply = ap('url', name)
    check(f'probe url {name}: 204 and starttransfer converted to integer 123 ms',
          reply == dict(ok=True, site=name, url=url, code=204, latency_ms=123))
    check(f'probe url {name}: exactly one bounded proxied request, no retry',
          CALLS.read_text().splitlines() == [
              'CALL', '--silent', '--output', '/dev/null', '--write-out',
              '%{http_code} %{time_starttransfer}', '--max-time', '2',
              '-x', 'http://127.0.0.1:31081', url])

for status in (200, 302, 399):
    reply = ap('url', 'apple', env={'URL_CURL_OUT': f'{status} 0.045'})
    check(f'probe url HTTP {status}: success', reply['ok'] and reply['latency_ms'] == 45)
for output, curl_rc, error, expected in (
    ('000 0.000', '28', 'timeout', 'PROBE_TIMEOUT'),
    ('500 0.100', '0', '', 'PROBE_FAILED'),
    ('199 0.100', '0', '', 'PROBE_FAILED'),
    ('400 0.100', '0', '', 'PROBE_FAILED'),
    ('000 0.000', '7', 'connection refused', 'PROBE_FAILED'),
    ('204 0.100', '7', 'connection failed despite output', 'PROBE_FAILED'),
    ('malformed output', '0', '', 'PROBE_FAILED'),
):
    reply = ap('url', 'google', rc=1,
               env={'URL_CURL_OUT': output, 'URL_CURL_RC': curl_rc, 'URL_CURL_ERR': error})
    check(f'probe url {output} exit {curl_rc}: {expected} and one request',
          reply['ok'] is False and reply['code'] == expected and reply['site'] == 'google'
          and CALLS.read_text().splitlines().count('CALL') == 1)
    if expected == 'PROBE_FAILED':
        check(f'probe url failure {output}: http_code and detail preserved',
              reply['http_code'] == (int(output[:3]) if output[:3].isdigit() else 0)
              and (error in reply['detail'] if error else bool(reply['detail'])))

# Exercise sys.run watchdog as well as curl's native exit 28.
CONFIG.write_text(CONFIG.read_text().replace("timeout '2'", "timeout '1'"))
reply = ap('url', 'google', rc=1, env={'URL_CURL_SLEEP': '8'})
check('probe url watchdog timeout: PROBE_TIMEOUT without mutations', reply['code'] == 'PROBE_TIMEOUT')
for args in (('url', 'unknown'), ('url', 'GOOGLE'), ('url', 'https://example.com'),
             ('url',), ('url', 'google', 'extra'), ('sites', 'extra')):
    reply = ap(*args, rc=2)
    check('probe rejects ' + ' '.join(args) + ': USAGE without curl',
          reply['code'] == 'USAGE' and CALLS.read_text() == '')
for service_state in ('degraded', 'failsafe', 'starting', 'stopped', 'error', None, 'corrupt'):
    if service_state is None:
        STATE.unlink()
    elif service_state == 'corrupt':
        STATE.write_text('{broken')
    else:
        STATE.write_text(json.dumps(dict(state=service_state)))
    reply = ap('url', 'google', rc=0 if service_state == 'degraded' else 1)
    check(f'probe url state {service_state}: correct availability and no side effects',
          reply['ok'] if service_state == 'degraded'
          else reply['code'] == 'NOT_RUNNING' and CALLS.read_text() == '')
check('probe url/sites all outcomes: state and events bytes/mtime unchanged per invocation', True)

STATE.write_text('{"state":"running"}')
CONFIG.write_text("config main 'main'\n option enabled 'invalid'\n")
reply = ap('url', 'google', rc=2)
check('probe url invalid configuration: CONFIG_INVALID without request or mutations',
      reply['code'] == 'CONFIG_INVALID' and CALLS.read_text() == '')
