#!/usr/bin/env python3
"""T11.11: real node parse/import boundary, persistence and credential safety."""
import base64
import json
from pathlib import Path
import subprocess
import sys

root, tmp = map(Path, sys.argv[1:])
conf = tmp / 'etc/config'
run = tmp / 'var/run/aether-proxy'
conf.mkdir(parents=True)
run.mkdir(parents=True)
config = conf / 'aetherproxy'
config.write_text("config global 'main'\n\toption enabled '0'\n")
ucode = str(root / 'tests/host/ucode')
fixture = root / 'tests/sub/fixtures/new-protocols.txt'
lines = fixture.read_text().splitlines()
secrets = ['SOCKS_SECRET', 'HTTP_SECRET', 'HY_SECRET', 'HY_ALIAS_SECRET',
           'PRIVATE_SECRET', 'PEER_SECRET', 'HTTP_BAD_SECRET', 'BASE64_SECRET',
           'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
           'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=']


def check(name, condition):
    assert condition, name
    print('PASS  T11.11 ' + name)


def ap(action, uri):
    result = subprocess.run([ucode, '-S', str(root / 'aether-proxy/src/aether-proxy'),
                             '--', 'node', action, uri, '--json', '--confdir', str(conf),
                             '--run-dir', str(run), '--sys-root', str(tmp)],
                            text=True, capture_output=True)
    check(action + ' has no stderr', not result.stderr)
    return result.returncode, json.loads(result.stdout)


for line, protocol in zip(lines[:7], ['socks', 'socks', 'http', 'http', 'hysteria', 'hysteria', 'wireguard']):
    rc, parsed = ap('parse', line)
    check(protocol + ' parse succeeds', rc == 0 and parsed['ok'] and parsed['node']['protocol'] == protocol)
    rc, imported = ap('import', line)
    check(protocol + ' import succeeds', rc == 0 and imported['ok'])
    check(protocol + ' import output hides credentials', not any(s in json.dumps(imported) for s in secrets))
    if protocol in ('socks', 'http') and 'noauth' in line:
        check(protocol + ' no-auth omits both fields', 'username' not in parsed['node'] and 'password' not in parsed['node'])

for line, reason in zip(lines[7:], ['missing_field', 'invalid_value', 'malformed', 'malformed']):
    for action in ('parse', 'import'):
        before = config.read_bytes()
        rc, value = ap(action, line)
        check(action + ' returns safe skip ' + reason,
              rc == 2 and value == dict(ok=False, code='CONFIG_INVALID', detail=reason))
        check(action + ' rejection leaves config unchanged', config.read_bytes() == before)

# URL-escaped standard Base64 must preserve username case and password colons.
userinfo = base64.b64encode(b'CaseUser:BASE64_PASSWORD:tail').decode().replace('=', '%3D')
rc, value = ap('parse', 'socks5://' + userinfo + '@b64.example:1080')
check('Base64 credentials preserve case and colons', rc == 0 and value['node']['username'] == 'CaseUser'
      and value['node']['password'] == 'BASE64_PASSWORD:tail')

result = subprocess.run([ucode, '-e', '''import * as uci from 'uci';
let c = uci.cursor(ARGV[0]); let nodes = [];
c.foreach('aetherproxy', 'node', n => { push(nodes, n); }); print(sprintf('%.J', nodes));''',
                         '--', str(conf)], text=True, capture_output=True, check=True)
nodes = json.loads(result.stdout)
check('all seven nodes persist as manual', len(nodes) == 7 and all(n['source'] == 'manual' for n in nodes))
wg = next(n for n in nodes if n['protocol'] == 'wireguard')
check('WireGuard list and zero persist', wg['local_address'] == ['10.0.0.2/32', '10.0.0.3/32'] and wg['keepalive'] == '0')
for path in run.rglob('*'):
    if path.is_file() and ('event' in path.name or 'log' in path.name):
        check('no credentials in ' + path.name, not any(s in path.read_text() for s in secrets))
