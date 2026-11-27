#!/usr/bin/env python3
"""T16.124: real SDK saves -> real CLI/curl -> recorded HTTP UA + parsed node.

No router, root, containers, package installs or downloads. Scratch is confined
within this worktree. SDK JavaScript is read, never copied into the repository.
"""
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
from threading import Thread

ROOT = Path(__file__).resolve().parents[2]
UCODE = ROOT / 'tests/host/ucode'
ENTRY = ROOT / 'aether-proxy/src/aether-proxy'
SID = 's_00000001'
ENV = {key: value for key, value in os.environ.items() if not key.lower().endswith('_proxy')}
PAYLOAD = (ROOT / 'tests/sub/fixtures/one-node.txt').read_bytes()


def run(argv, **kwargs):
    result = subprocess.run([str(arg) for arg in argv], cwd=ROOT, env=ENV,
                            text=True, capture_output=True, timeout=120, **kwargs)
    if result.returncode:
        raise AssertionError(f"command failed ({result.returncode}): {argv}\n"
                             f"{result.stdout}\n{result.stderr}")
    return result.stdout


def quote(value):
    return "'" + str(value).replace("'", "'\\''") + "'"


def config_text(sections):
    lines = []
    for sid, section in sections.items():
        lines.append(f"config {section['.type']} {quote(sid)}")
        for key, value in section.items():
            if key.startswith('.'):
                continue
            assert not isinstance(value, (dict, list)), (key, value)
            lines.append(f"\toption {key} {quote(value)}")
        lines.append('')
    return '\n'.join(lines)


def check(name, condition):
    if not condition:
        raise AssertionError(name)
    print('PASS T16.124 ' + name, flush=True)


def main():
    default_ua = run([UCODE, '-e', "import * as C from 'aetherproxy.const'; "
                      "print(C.PROG + '/' + C.VERSION);"]).strip()
    ENV['T124_DEFAULT_UA'] = default_ua
    seen = []

    class Endpoint(BaseHTTPRequestHandler):
        def do_GET(self):
            seen.append((self.path, self.headers.get_all('User-Agent')))
            body = base64.b64encode(PAYLOAD) if self.path.endswith('/base64') else PAYLOAD
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass  # Only the controlled fixture; the application stderr is retained on failure.

    server = ThreadingHTTPServer(('127.0.0.1', 0), Endpoint)
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='tmp.', dir=Path(__file__).parent) as temporary:
            scratch = Path(temporary)
            snapshots = scratch / 'sdk-saves.json'
            # Preserve the real browser output. Missing SDK/browser is a failure, not SKIP.
            browser = run(['node', ROOT / 'tests/t16-124/sdk-save.cjs', snapshots])
            print(browser, end='', flush=True)
            cases = json.loads(snapshots.read_text())
            check('SDK produced independent saved scenarios', len(cases) >= 16)
            for index, case in enumerate(cases):
                root = scratch / f'http-{index}'
                conf = root / 'etc/config'
                run_dir = root / 'var/run/aether-proxy'
                for directory in (conf, run_dir, root / 'etc/aether-proxy/state',
                                  root / 'etc/aether-proxy/custom', root / 'var/lock',
                                  root / 'usr/share/aether-proxy', root / 'tmp',
                                  root / 'delta', root / 'read-delta'):
                    directory.mkdir(parents=True, exist_ok=True)
                (root / 'usr/share/aether-proxy/data').symlink_to(ROOT / 'aether-proxy/files/data')
                sections = case['sections']
                for encoding in ('plain', 'base64'):
                    sections[SID]['url'] = f'http://127.0.0.1:{server.server_port}/{index}/{encoding}'
                    config_file = conf / 'aetherproxy'
                    if encoding == 'plain':
                        config_file.write_text(config_text(sections))
                    else:
                        # Keep imported nodes; only change the fixture URL through real UCI.
                        run([UCODE, '-e', "import * as uci from 'uci'; "
                             "let c = uci.cursor(ARGV[0], ARGV[1]); "
                             "if (!c.set('aetherproxy', ARGV[2], 'url', ARGV[3]) || "
                             "!c.commit('aetherproxy')) die('fixture URL update failed');",
                             '--', conf, root / 'delta', SID, sections[SID]['url']])
                    before = len(seen)
                    result = json.loads(run([UCODE, '-S', ENTRY, '--', 'sub', 'update', SID,
                                             '--json', '--confdir', conf, '--sys-root', root,
                                             '--run-dir', run_dir]))
                    label = case['name'] + ' / ' + encoding
                    check(label + ': update succeeds', result['ok'] and result['subs'][SID]['ok'])
                    check(label + ': exact actual HTTP User-Agent',
                          len(seen) == before + 1 and seen[-1] ==
                          (f'/{index}/{encoding}', [case['expected']]))
                    # Read the committed configuration with the production loader, not a regex.
                    saved = json.loads(run([UCODE, '-e', "import * as uci from 'uci'; "
                        "import * as config from 'aetherproxy.config'; "
                        "let c = uci.cursor(ARGV[0], ARGV[1]); let r = config.load(c); "
                        "if (!r.ok) die(sprintf('%.J', r)); printf('%.J', r.snapshot);",
                        '--', conf, root / 'read-delta']))
                    nodes = list(saved['nodes'].values())
                    check(label + ': one supported VLESS node was parsed and committed',
                          len(nodes) == 1 and nodes[0]['protocol'] == 'vless'
                          and nodes[0]['address'] == 'edge.example.com'
                          and nodes[0]['uuid'] == '11111111-2222-4333-8444-555555555555'
                          and nodes[0]['source'] == SID)
                    record = json.loads((root / 'etc/aether-proxy/state/sub.json').read_text())[SID]
                    check(label + ': successful parse recorded in subscription status',
                          record.get('error') is None and record['nodes'] == 1 and record['last_ok'] > 0)
                    check(label + ': fetch method stays direct',
                          saved['subscriptions'][SID]['fetch_via'] == 'direct')
            print(f'PASS T16.124 {len(cases) * 2} real HTTP requests verified; no device access', flush=True)
    finally:
        server.shutdown()
        thread.join(timeout=5)
        server.server_close()


if __name__ == '__main__':
    main()
