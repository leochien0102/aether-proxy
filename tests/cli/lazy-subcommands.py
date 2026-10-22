#!/usr/bin/env python3
"""T10.8: docs/10 lazy CLI dispatch, tested with deliberately broken module copies."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / 'aether-proxy/src/lib'
ENTRY = ROOT / 'aether-proxy/src/aether-proxy'
PREFIX = ROOT / 'tests/host/prefix'

# Freeze the help bytes (T9.20 adds node use/mode use): comparing help to
# unknown-command output alone would miss a shared accidental change to USAGE.
USAGE = b'''Usage: aether-proxy <command> [options]

Commands:
  version [--json]   print the installed version
  check [--json]     validate the configuration and render into staging
  render <name>      print one artifact (xray|nft|chinadns|dnsmasq)
  status [--json]    print the latest runtime state
  components [--json] find installed components and read their versions
  stats [--json]     read traffic and connection counters
  events [options]   list structured events
  probe now          request an immediate proxy health check
  probe nodes        test TCP reachability of subscription nodes
  probe results      print the latest node reachability results
  sub status         read subscription update records
  sub update         download and atomically apply subscriptions
  node import <uri>  import a share-link URI as a manual node
  node use <id> [--mode <mode>] select the current node and optionally default mode
  mode use <mode>    select the default mode (gfw|bypass_cn|global)
  custom get|set     read or validate-and-save a custom list file
  log [options]      read recent tagged lines from logd
  data status        inspect local rule data and available updates
  update check       check signed package and data updates
  job start          start a long-running command as a background job
  job status         print the state of a background job
  daemon [--boot]    start and supervise proxy components
  cleanup            remove runtime system state
  --help             show this help
'''


def check(name, condition):
    if not condition:
        raise AssertionError(name)
    print('PASS  T10.8 lazy: ' + name, flush=True)


def signature(result):
    return result.returncode, result.stdout, result.stderr


source = ENTRY.read_text()
imports = re.findall(r'^import\s+.*?\s+from\s+[\'"]([^\'"]+)[\'"];', source, re.M)
check('only static import is const', imports == ['aetherproxy.const'])
usage = re.search(r'const USAGE = `([^`]+)`;', source).group(1)
commands = set(re.findall(r'^  ([a-z]+)\b', usage, re.M))
table = re.search(r'const COMMAND_MODULES = \{\n(.*?)\n\};', source, re.S).group(1)
entries = []
for line in table.splitlines():
    match = re.fullmatch(r"\s*([a-z]+): '(aetherproxy\.cmd\.[a-z]+)',", line)
    check('fixed module table entry ' + line.strip(), match is not None)
    entries.append(match.groups())
modules = dict(entries)
check('module table exactly covers USAGE except inline version',
      set(modules) == commands - {'version'} and len(modules) == len(entries))
check('module names match fixed command paths',
      all(module == 'aetherproxy.cmd.' + name for name, module in entries))

with tempfile.TemporaryDirectory(prefix='.lazy-', dir=ROOT / 'tests/cli') as temp:
    base = Path(temp)
    copied = base / 'modules/aetherproxy'
    shutil.copytree(LIB, copied)
    run = base / 'run'
    config = base / 'config'
    system = base / 'root'
    binaries = base / 'bin'
    for directory in (run, config, system, binaries):
        directory.mkdir()
    shutil.copyfile(ROOT / 'tests/fixtures/sample/aetherproxy', config / 'aetherproxy')
    (run / 'state.json').write_text('{"state":"running","future_field":{"kept":true}}\n')

    # Even accidental logging must stay in the private directory. The real host
    # binary is used directly so no wrapper search path can bypass the broken copy.
    constants = copied / 'const.uc'
    text, count = re.subn(r"export const RUN_DIR = '[^']+';",
                          f"export const RUN_DIR = '{run}';", constants.read_text())
    assert count == 1
    constants.write_text(text)
    env = dict(os.environ, LD_LIBRARY_PATH=str(PREFIX / 'lib'))
    command = [str(PREFIX / 'bin/ucode'), '-L', str(base / 'modules/*.uc'),
               '-L', str(PREFIX / 'lib/ucode/*.so'), '-S', str(ENTRY), '--']

    def invoke(*args):
        return subprocess.run(command + list(args), env=env, capture_output=True, timeout=10)

    def check_inline(phase):
        version = invoke('version', '--json')
        check(phase + ': version JSON succeeds unchanged', signature(version) == version_before)
        check(phase + ': version human succeeds unchanged',
              signature(invoke('version')) == human_before)
        for flag in ('--help', '-h'):
            check(phase + ': ' + flag + ' exact help bytes',
                  signature(invoke(flag)) == (0, USAGE, b''))
        for args in (('not-a-command',), ('not-a-command', '--json'), (),
                     ("log'; import * as x from 'aetherproxy.cmd.log",)):
            label = ' '.join(args) if args else '<no command>'
            check(phase + ': USAGE exit 2 exact bytes for ' + label,
                  signature(invoke(*args)) == (2, b'', USAGE))

    def break_module(name):
        (copied / 'cmd' / (name + '.uc')).write_text("'use strict';\nexport function broken(\n")

    def check_load_failure(name, *args):
        result = invoke(name, '--json', *args)
        check('broken ' + name + ': uncaught syntax error and nonzero exit',
              result.returncode != 0 and result.stdout == b''
              and b'Syntax error' in result.stderr and (name + '.uc').encode() in result.stderr)

    version_result = invoke('version', '--json')
    value = json.loads(version_result.stdout)
    check('intact version is one JSON object with empty stderr',
          version_result.returncode == 0 and version_result.stderr == b''
          and value['ok'] is True and isinstance(value['version'], str))
    version_before = signature(version_result)
    human_before = (0, ('aether-proxy ' + value['version'] + '\n').encode(), b'')
    status_args = ('--run-dir', str(run), '--confdir', str(config),
                   '--sys-root', str(system), '--bin-dir', str(binaries))
    status_before = signature(invoke('status', '--json', *status_args))
    status = json.loads(status_before[1])
    check('intact status succeeds with populated isolated state',
          status_before[0] == 0 and status_before[2] == b''
          and status['state'] == 'running' and status['future_field'] == {'kept': True})
    check_inline('intact modules')

    break_module('log')
    check_inline('broken log')
    check('broken log: status output and exit unchanged',
          signature(invoke('status', '--json', *status_args)) == status_before)
    check_load_failure('log')

    break_module('status')
    check_inline('broken log and status')
    check_load_failure('status', *status_args)
    check('read-only and usage commands do not write events', not (run / 'events.jsonl').exists())
