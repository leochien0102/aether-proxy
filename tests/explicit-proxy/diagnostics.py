#!/usr/bin/env python3
"""Offline real-CLI regression tests for secret-bearing validator diagnostics."""

import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile

from acceptance import ROOT, UCODE, NODE, check


# The validator must consume the real rendered accounts, not just echo a fixture.
# Disabled-but-retained accounts are intentionally absent from the artifact; only
# that case gets sentinel values through the environment.
VALIDATOR = '''import json
import os
from pathlib import Path
import sys

if sys.argv[1:] == ['version']:
    print('Xray 26.11.9')
    sys.exit(0)
if sys.argv[1:4] != ['run', '-test', '-c']:
    sys.exit(9)
config = json.loads(Path(sys.argv[4]).read_text())
accounts = [account for inbound in config['inbounds']
            for account in inbound.get('settings', {}).get('accounts', [])]
expected = json.loads(os.environ['DIAGNOSTIC_ACCOUNTS'])
if os.environ['DIAGNOSTIC_ENABLED'] == '1':
    if sorted((a['user'], a['pass']) for a in accounts) != sorted(map(tuple, expected)):
        sys.exit(8)
    values = [a[key] for a in accounts for key in ('user', 'pass')]
else:
    if accounts:
        sys.exit(7)
    values = [value for account in expected for value in account]
for stream in (sys.stdout, sys.stderr):
    for value in values:
        print(value, file=stream)
        print(json.dumps(value), file=stream)
Path(os.environ['DIAGNOSTIC_MARKER']).write_text('raw+json stdout+stderr')
sys.exit(1)
'''


def uci_quote(value):
    # UCI supports adjacent quoted fragments; never interpolate raw apostrophes.
    return "'" + value.replace("'", "'\\''") + "'"


def write_config(confdir, enabled, accounts, missing=None):
    lines = ["config main 'main'", " option enabled '1'", f" option node '{NODE}'",
             " list lan_ifaces 'br-lan'"]
    for protocol, (username, password) in accounts.items():
        lines += [f" option {protocol}_enabled '{int(enabled)}'",
                  f" option {protocol}_port '{32180 if protocol == 'socks' else 32181}'",
                  f" option {protocol}_listen '192.0.2.1'"]
        for field, value in (('username', username), ('password', password)):
            if f'{protocol}_{field}' != missing:
                lines.append(f' option {protocol}_{field} {uci_quote(value)}')
    lines += ["config dns 'dns'", " list china_dns '127.0.0.1'",
              " list trust_dns '127.0.0.1'", f"config node '{NODE}'",
              " option protocol 'socks'", " option address '127.0.0.1'",
              " option port '1080'"]
    path = confdir / 'aetherproxy'
    path.write_text('\n'.join(lines) + '\n')
    path.chmod(0o600)


def assert_no_secrets(output, values, label):
    for value in values:
        # Replies/events JSON-encode details again, so check both raw and nested
        # escaped representations, not merely decoded top-level fields.
        forms = {value}
        for _ in range(3):
            forms |= {json.dumps(form)[1:-1] for form in forms}
        check(not any(form.encode() in output for form in forms),
              label + ': credential leaked (output withheld)')


def run_case(work, bin_dir, sysroot, name, enabled, accounts, missing=None):
    case = work / name
    confdir = case / 'config'
    confdir.mkdir(parents=True)
    for directory in ('data', 'base', 'custom', 'run'):
        (case / directory).mkdir()
    for filename in ('gfwlist', 'chnlist', 'apple'):
        (case / 'base' / (filename + '.txt')).write_text('example.invalid\n')
    for filename in ('chnroute4', 'gfw_static4'):
        (case / 'base' / (filename + '.txt')).write_text('192.0.2.0/24\n')
    write_config(confdir, enabled, accounts, missing)
    marker = case / 'validator-ran'
    env = dict(os.environ, DIAGNOSTIC_ACCOUNTS=json.dumps(list(accounts.values())),
               DIAGNOSTIC_ENABLED=str(int(enabled)), DIAGNOSTIC_MARKER=str(marker))
    command = [str(UCODE), '-S', str(ROOT / 'aether-proxy/src/aether-proxy'), '--',
               'check', '--json', '--confdir', str(confdir),
               '--data-dir', str(case / 'data'), '--baseline-dir', str(case / 'base'),
               '--custom-dir', str(case / 'custom'), '--run-dir', str(case / 'run'),
               '--bin-dir', str(bin_dir), '--sys-root', str(sysroot)]
    result = subprocess.run(command, env=env, capture_output=True, timeout=30)
    values = [value for account in accounts.values() for value in account]
    events_path = case / 'run/events.jsonl'
    check(events_path.is_file(), name + ': missing events.jsonl')
    events_bytes = events_path.read_bytes()
    for label, output in (('reply', result.stdout), ('stderr', result.stderr),
                          ('events.jsonl', events_bytes)):
        assert_no_secrets(output, values, name + ' ' + label)
    check(not result.stderr, name + ': unexpected stderr (withheld)')
    try:
        reply = json.loads(result.stdout)
        events = [json.loads(line) for line in events_bytes.splitlines()]
    except (ValueError, UnicodeError):
        raise AssertionError(name + ': invalid diagnostic JSON (output withheld)') from None
    expected = 'CONFIG_INVALID' if missing else 'RENDER_INVALID'
    check(result.returncode == (2 if missing else 4), name + ': unexpected CLI exit')
    check(reply.get('ok') is False and reply.get('code') == expected,
          name + ': wrong reply outcome')
    check(any(event.get('code') == expected for event in events),
          name + ': missing failure event')
    if missing:
        check(not marker.exists(), name + ': config error unexpectedly ran validator')
        check(any(error.get('field') == 'main.' + missing and error.get('code') == 'required'
                  for error in reply.get('errors', [])), name + ': missing required-field error')
    else:
        check(marker.is_file() and marker.read_text() == 'raw+json stdout+stderr',
              name + ': validator did not verify accounts and emit credentials')
        errors = reply.get('errors', [])
        check(len(errors) == 1 and errors[0].get('item') == 'xray',
              name + ': failure did not originate from Xray')
        check('output withheld' in errors[0].get('detail', ''),
              name + ': missing safe validator diagnostic')
    check(not list((case / 'run').glob('check.*')), name + ': check scratch remains')
    print('PASS ' + name)
    return case, env


def run_node_case(case, env, bin_dir, sysroot, accounts):
    target = 'n_' + '2' * 32
    config = case / 'config/aetherproxy'
    content = config.read_text().replace("config main 'main'\n",
              "config main 'main'\n option xray_bin " + uci_quote(str(bin_dir / 'xray')) + '\n')
    content += (f"config node '{target}'\n option protocol 'socks'\n"
                " option address '127.0.0.2'\n option port '1080'\n")
    config.write_text(content)
    state = case / 'run/state.json'
    state.write_text('{"state":"stopped"}\n')
    events_path = case / 'run/events.jsonl'
    events_before = events_path.read_bytes()
    marker = Path(env['DIAGNOSTIC_MARKER'])
    marker.unlink()
    result = subprocess.run([str(UCODE), '-S', str(ROOT / 'aether-proxy/src/aether-proxy'),
                             '--', 'node', 'use', target, '--json',
                             '--confdir', str(case / 'config'), '--run-dir', str(case / 'run'),
                             '--sys-root', str(sysroot)], env=env, capture_output=True, timeout=30)
    label = case.name + ' node-use'
    values = [value for account in accounts.values() for value in account]
    for output in (result.stdout, result.stderr, events_path.read_bytes()):
        assert_no_secrets(output, values, label)
    check(not result.stderr, label + ': unexpected stderr (withheld)')
    try:
        reply = json.loads(result.stdout)
    except (ValueError, UnicodeError):
        raise AssertionError(label + ': invalid JSON (output withheld)') from None
    check(result.returncode == 1 and reply.get('ok') is False
          and reply.get('code') == 'CONFIG_INVALID' and reply.get('committed') is False,
          label + ': wrong refusal outcome')
    check('output withheld' in reply.get('detail', ''), label + ': missing safe diagnostic')
    check(marker.is_file() and marker.read_text() == 'raw+json stdout+stderr',
          label + ': malicious validator did not run')
    check(config.read_text() == content and state.read_text() == '{"state":"stopped"}\n',
          label + ': preflight refusal changed config/state')
    check(events_path.read_bytes() == events_before, label + ': unexpected event history change')
    check(not list((case / 'run').glob('node-use.*')), label + ': preflight scratch remains')
    print('PASS ' + label)


def main():
    check(UCODE.is_file(), 'tests/host/ucode unavailable; run tests/host/bootstrap.sh')
    accounts = {protocol: tuple(secrets.token_hex(12) + suffix
                               for suffix in ('-user\'"\\tail', '-pass\\"\'end'))
                for protocol in ('socks', 'http')}
    with tempfile.TemporaryDirectory(prefix='aether-explicit-diagnostics-') as temp:
        work = Path(temp)
        bin_dir = work / 'bin'
        bin_dir.mkdir()
        sysroot = work / 'root'
        (sysroot / 'sys/class/net/br-lan').mkdir(parents=True)
        stubs = {'nft': '#!/bin/sh\n[ -s "$3" ]\n',
                 'ip': '#!/bin/sh\nif [ "$1" = "-j" ]; then\n'
                       ' echo \'[ {"ifname":"br-lan","addr_info":'
                       '[{"family":"inet","local":"192.0.2.1"}]} ]\'\n'
                       'else echo "Usage: ip rule [ fwmark FWMARK[/MASK] ]"; fi\n',
                 'chinadns-ng': '#!/bin/sh\nexit 0\n',
                 'xray': '#!' + sys.executable + '\n' + VALIDATOR}
        for name, content in stubs.items():
            path = bin_dir / name
            path.write_text(content)
            path.chmod(0o700)
        for name, enabled in (('enabled-credentials', True), ('disabled-retained-credentials', False)):
            case, env = run_case(work, bin_dir, sysroot, name, enabled, accounts)
            run_node_case(case, env, bin_dir, sysroot, accounts)
        for protocol in ('socks', 'http'):
            for field in ('username', 'password'):
                missing = protocol + '_' + field
                run_case(work, bin_dir, sysroot, 'missing-' + missing, True, accounts, missing)
    print('PASS offline diagnostic regressions (8 cases)')


if __name__ == '__main__':
    try:
        main()
    except AssertionError as error:
        # Assertion messages contain fixed labels only, never captured output.
        print('FAIL ' + str(error), file=sys.stderr)
        sys.exit(1)
    except Exception:
        # Parser exceptions can include secret-bearing validator output.
        print('FAIL offline diagnostic regressions (details withheld)', file=sys.stderr)
        sys.exit(1)
