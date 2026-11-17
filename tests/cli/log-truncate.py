#!/usr/bin/env python3
"""T16.9 public CLI contract, including retained collector descriptors and I/O errors."""
import datetime
import json
import os
from pathlib import Path
import resource
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
CMD = [str(ROOT / 'tests/host/ucode'), '-S', str(ROOT / 'aether-proxy/src/aether-proxy'), '--',
       'log', 'truncate']


def check(name, condition):
    assert condition, name
    print('PASS  T16.9 ' + name)


def call(directory, *args, code=0, preexec_fn=None):
    p = subprocess.run(CMD + ['--run-dir', str(directory), '--json', *args],
                       capture_output=True, text=True, preexec_fn=preexec_fn)
    check('CLI exit and empty stderr', p.returncode == code and not p.stderr)
    value = json.loads(p.stdout)
    check('JSON is a single object', isinstance(value, dict))
    return value


def fail_writes():
    # Deterministic kernel write failure, even when the test runner is root.
    signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
    resource.setrlimit(resource.RLIMIT_FSIZE, (1, 1))


with tempfile.TemporaryDirectory(prefix='.log-truncate-', dir=ROOT / 'tests/cli') as temp:
    directory = Path(temp)
    now = datetime.datetime.now().replace(microsecond=0)
    since = int(now.timestamp())
    current = now.strftime('%b %d %H:%M:%S host tag[1]: current\n')
    # A cutoff at this second retains exactly this line, independent of test execution duration.
    contents = {
        'events.jsonl': '{"ts":0}\n' + json.dumps({'ts': since}) + '\nbad\n',
        'raw.log': 'bad\n' + current,
        'raw.log.1': 'bad\nalso bad\n',
    }
    (directory / 'state.json').write_text(json.dumps({'since': since}))
    for name, text in contents.items():
        (directory / name).write_text(text)
    before = {name: (directory / name).stat().st_ino for name in contents}
    with (directory / 'raw.log').open('a') as collector:
        value = call(directory)
        check('default since comes from state.json', value['since'] == since)
        check('JSON kept and dropped counts independently cover three files', value == {
            'ok': True, 'since': since,
            'kept': {'events': 1, 'raw': 1, 'raw1': 0},
            'dropped': {'events': 2, 'raw': 1, 'raw1': 2},
        })
        for name in contents:
            file = directory / name
            check('inode preserved for ' + name, file.stat().st_ino == before[name])
            print(f'EVIDENCE {name}: before={len(contents[name].splitlines())} lines/'
                  f'{len(contents[name].encode())} bytes; after={len(file.read_text().splitlines())}'
                  f' lines/{file.stat().st_size} bytes; inode={before[name]}->{file.stat().st_ino}')
        check('raw bytes retained exactly', (directory / 'raw.log').read_text() == current)
        check('entire expired raw1 truncated to zero bytes', (directory / 'raw.log.1').stat().st_size == 0)
        collector.write(current)
        collector.flush()
        check('held collector descriptor still appends to visible file',
              (directory / 'raw.log').read_text() == current * 2)
    value = call(directory, '--since', '0')
    check('explicit since overrides startup marker', value['since'] == 0)
    # Human mode also exposes an observable successful result.
    human = subprocess.run(CMD + ['--run-dir', str(directory), '--since', '0'], capture_output=True, text=True)
    check('human success output', human.returncode == 0 and 'logs truncated since' in human.stdout)
    (directory / 'state.json').unlink()
    check('missing startup marker NOT_RUNNING', call(directory, code=2)['code'] == 'NOT_RUNNING')
    for marker in ['bad', '{}', '{"since":"1"}', '{"since":-1}', '{"since":null}']:
        (directory / 'state.json').write_text(marker)
        check('invalid startup marker NOT_RUNNING', call(directory, code=2)['code'] == 'NOT_RUNNING')
    for args in [('--since', '-1'), ('--since', '1.5'), ('--since', 'bad'), ('--since',),
                 ('--since', '1', '--since', '2'), ('--lines', '1'), ('extra',),
                 ('--since', '99999999999999999999999999999')]:
        check('invalid CLI arguments USAGE', call(directory, *args, code=2)['code'] == 'USAGE')
    for name in contents:
        (directory / name).unlink()
    value = call(directory, '--since', '0')
    check('missing files are successful zero counts', value['ok'] and
          value['kept'] == value['dropped'] == {'events': 0, 'raw': 0, 'raw1': 0})
    (directory / 'events.jsonl').write_text('{"ts":1}\n{"ts":2}\n')
    value = call(directory, '--since', '0', code=1, preexec_fn=fail_writes)
    check('kernel write failure FS_FAILED', value['code'] == 'FS_FAILED')
    (directory / 'events.jsonl').unlink()
    (directory / 'events.jsonl').mkdir()
    check('filesystem read failure FS_FAILED', call(directory, '--since', '0', code=1)['code'] == 'FS_FAILED')

print('T16.9 log truncate CLI scenarios passed')
