#!/usr/bin/env python3
"""T9.13: parse/import parity and read-only CLI behavior (docs/10 node parse)."""
import base64
import fcntl
import json
from pathlib import Path
import subprocess
import sys
from urllib.parse import quote, urlencode

ROOT = Path(sys.argv[1])
T = Path(sys.argv[2])
UCODE = ROOT / 'tests/host/ucode'
CONF = T / 'etc/config'
RUN = T / 'var/run/aether-proxy'
SAVEDIR = T / 'session'
LOCK = T / 'var/lock/aether-proxy-sub.lock'
for directory in (CONF, RUN, SAVEDIR, LOCK.parent):
    directory.mkdir(parents=True, exist_ok=True)
CONFIG = CONF / 'aetherproxy'
BASE = "config global 'main'\n\toption enabled '0'\n"
CONFIG.write_text(BASE)


def check(name, condition):
    if not condition:
        raise AssertionError(name)
    print('PASS  ' + name)


def uc(source, *args):
    result = subprocess.run([str(UCODE), '-e', source, '--', *map(str, args)],
                            text=True, capture_output=True, check=True)
    assert not result.stderr, result.stderr
    return json.loads(result.stdout)


def ap(action, uri=None, rc=0, context=True, json_output=True):
    args = ['node', action] + ([] if uri is None else [uri])
    if json_output:
        args += ['--json']
    if context:
        args += ['--confdir', str(CONF), '--run-dir', str(RUN), '--sys-root', str(T)]
    result = subprocess.run([str(UCODE), '-S', str(ROOT / 'aether-proxy/src/aether-proxy'), '--', *args],
                            text=True, capture_output=True)
    assert result.returncode == rc, (args[:3], result.returncode, result.stdout, result.stderr)
    assert not result.stderr, result.stderr
    return json.loads(result.stdout)


READ_NODES = '''
import * as uci from 'uci';
let c = uci.cursor(ARGV[0]);
let out = {};
c.foreach('aetherproxy', 'node', n => { out[n['.name']] = n; });
print(sprintf('%.J', out));
'''


def options(n):
    return {k: v for k, v in n.items()
            if not k.startswith(('.', 'match_')) and k not in ('source', 'stale')}


# Reuse the existing URI corpus, including independent expected option values.
corpus = uc(f"import * as fixture from '{ROOT}/tests/unit/uri.uc'; "
            "print(sprintf('%.J', filter(fixture.cases, c => c.fn == 'line')));")


def fixture_uri(n):
    """Encode existing render fixture options as sharing syntax, not production parsing."""
    protocol = n['protocol']
    if protocol == 'vmess':
        mappings = dict(label='ps', address='add', port='port', uuid='id', method='scy',
                        transport='net', security='tls', header_type='type', host='host',
                        path='path', sni='sni', fingerprint='fp', alpn='alpn')
        payload = {v: ','.join(n[k]) if isinstance(n[k], list) else n[k]
                   for k, v in mappings.items() if k in n}
        payload['net'] = 'tcp' if n.get('transport', 'raw') == 'raw' else n['transport']
        payload['tls'] = 'tls' if n.get('security') == 'tls' else ''
        return 'vmess://' + base64.b64encode(json.dumps(payload).encode()).decode()
    if protocol == 'shadowsocks':
        credentials = base64.b64encode((n['method'] + ':' + n['password']).encode()).decode()
        return f"ss://{credentials}@{n['address']}:{n['port']}#" + quote(n.get('label', ''))
    mappings = dict(transport='type', security='security', sni='sni', alpn='alpn',
                    fingerprint='fp', reality_pbk='pbk', reality_sid='sid', reality_spx='spx',
                    flow='flow', encryption='encryption', host='host', path='path',
                    service_name='serviceName', xhttp_mode='mode', header_type='headerType',
                    pinned_cert_sha256='pcs', verify_name='vcn')
    query = {v: ','.join(n[k]) if isinstance(n[k], list) else n[k]
             for k, v in mappings.items() if k in n}
    if query.get('type') == 'raw':
        query['type'] = 'tcp'
    user = n['uuid'] if protocol == 'vless' else n['password']
    return (f"{protocol}://{quote(user, safe='')}@{n['address']}:{n['port']}?"
            + urlencode(query) + '#' + quote(n.get('label', '')))


# tests/fixtures contains UCI render fixtures, not literal sharing links. Exercise
# their protocol/transport combinations too, without editing those shared fixtures.
for fixture in sorted((ROOT / 'tests/fixtures').glob('t16-*/aetherproxy')):
    for n in uc(READ_NODES, fixture.parent).values():
        corpus.append(dict(name=fixture.parent.name, input=fixture_uri(n), expect=dict(node=options(n))))

for case in corpus:
    name, uri, expected = case['name'], case['input'], case['expect']
    if 'node' not in expected:
        parsed = ap('parse', uri, rc=2)
        imported = ap('import', uri, rc=2)
        check(f'node parse failure {name}: same code/detail/exit as import',
              parsed == imported == dict(ok=False, code='CONFIG_INVALID', detail=expected['skip']))
        continue
    CONFIG.write_text(BASE)
    parsed = ap('parse', uri)
    imported = ap('import', uri)
    committed = uc(READ_NODES, CONF)[imported['node']]
    check(f'node parse parity {name}: exact committed UCI options and types',
          parsed == dict(ok=True, node=options(committed)))
    # Existing unit corpus has parser-level expectations; render fixtures may
    # explicitly store defaults that are absent in the sharing format.
    if not name.startswith('t16-'):
        want = {k: str(v) if isinstance(v, int) else v for k, v in expected['node'].items()}
        want.setdefault('label', f"{want['address']}:{want['port']}")
        check(f'node parse values {name}: independent fixture expectation', parsed['node'] == want)
    check(f'node parse types {name}: strings or lists of strings, no metadata',
          all(isinstance(v, str) or (isinstance(v, list) and all(isinstance(x, str) for x in v))
              for v in parsed['node'].values()) and parsed['node'] == options(parsed['node']))

uri = 'trojan://secret@tj.example:443?alpn=h2,http%2F1.1&allowInsecure=true'
parsed = ap('parse', uri)
check('node parse unnamed: address:port label and multi-value alpn array',
      parsed['node']['label'] == 'tj.example:443' and parsed['node']['alpn'] == ['h2', 'http/1.1'])
check('node parse empty alpn: omitted', 'alpn' not in ap('parse', uri.replace('h2,http%2F1.1', ''))['node'])
pure = uc('''
import * as node from 'aetherproxy.node';
print(sprintf('%.J', node.node_options({ protocol: 'trojan', address: 'host', port: 443,
    alpn: [], source: 'manual', stale: '1', match_strong: 'hidden', match_weak: 'hidden' })));
''')
check('node options pure conversion: empty list and all metadata omitted',
      pure == dict(label='host:443', protocol='trojan', address='host', port='443'))

# A real libuci savedir, with an uncommitted change, must remain untouched.
CONFIG.write_text(BASE)
uc('''
import * as uci from 'uci';
let c = uci.cursor(ARGV[0], ARGV[1]);
if (!c.set('aetherproxy', 'main', 'mode', 'global') || !c.save('aetherproxy')) exit(1);
print('true');
''', CONF, SAVEDIR)
(RUN / 'events.jsonl').write_text('existing event\n')


def snapshot():
    # Ignore access time, which our own byte comparison may update.
    return {str(p.relative_to(T)): (p.stat().st_ino, p.stat().st_mtime_ns, p.stat().st_ctime_ns,
                                   p.read_bytes() if p.is_file() else None)
            for p in T.rglob('*')}


with LOCK.open('a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    check('node parse lock setup: import reports BUSY while subscription lock held',
          ap('import', uri, rc=3)['code'] == 'BUSY')
    before = snapshot()
    check('node parse held subscription lock: succeeds including warning URI', ap('parse', uri)['ok'])
    ap('parse', 'vless://malformed', rc=2)
    for invalid in ('', 'foo', '1bad://host', ' vless://x', 'vless://' + 'a' * 4090,
                    'trojan://x@h:443#' + '中' * 1400):
        check('node parse invalid boundary: USAGE exit 2', ap('parse', invalid, rc=2)['code'] == 'USAGE')
    for length in (4096, 4097):
        prefix = 'trojan://secret@tj.example:443#'
        value = prefix + 'a' * (length - len(prefix))
        reply = ap('parse', value, rc=0 if length == 4096 else 2)
        check(f'node parse {length} bytes: exact boundary', reply['ok'] == (length == 4096))
    check('node parse all outcomes: config/savedir/locks/events bytes and metadata unchanged', snapshot() == before)

# No valid context is needed at all: parse must never try to load configuration.
CONFIG.write_text('invalid UCI !!!')
check('node parse corrupt config: succeeds without reading it', ap('parse', uri)['ok'])
CONFIG.unlink()
CONF.rmdir()
check('node parse absent config directory: succeeds without resolving it', ap('parse', uri)['ok'])
check('node parse default context: succeeds without host configuration', ap('parse', uri, context=False)['ok'])
check('node parse without --json: documented success object', ap('parse', uri, json_output=False)['ok'])
check('node parse missing argument: USAGE', ap('parse', rc=2)['code'] == 'USAGE')
