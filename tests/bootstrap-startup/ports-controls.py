#!/usr/bin/env python3
"""T15.9 precise negative controls, only in independent temporary file copies."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
EVIDENCE = HERE / 'evidence/t15.9'
OLD_INIT = '''    def __init__(self, ip='192.0.2.17', negative=False, silent=False, port=0):
        self.ip, self.negative, self.silent = ip, negative, silent
        self.requests = []
        self.done = threading.Event()
        self.udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.udp.bind(('127.0.0.1', port))
        self.port = self.udp.getsockname()[1]
        self.tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.tcp.bind(('127.0.0.1', self.port))
        self.tcp.listen()
        self.thread = threading.Thread(target=self.serve)
        self.thread.start()

'''


def control(name, source, case, expected):
    with tempfile.TemporaryDirectory(prefix='.ports-control-', dir=HERE) as directory:
        root = Path(directory)
        target = root / 'tests/bootstrap-startup'
        target.mkdir(parents=True)
        (target / 'run.py').write_text(source)
        shutil.copy2(HERE / 'ports.py', target / 'ports.py')
        helpers = root / 'tests/xray-ready'
        helpers.mkdir()
        for filename in ('lifecycle.py', 'proc_fixture.py'):
            shutil.copy2(ROOT / 'tests/xray-ready' / filename, helpers / filename)
        result = subprocess.run([sys.executable, str(target / 'ports.py'), 'Ports.' + case],
                                capture_output=True, text=True, timeout=30)
        output = result.stdout + result.stderr
        (EVIDENCE / (name + '.log')).write_text(output)
        assert result.returncode == 1 and expected in output and 'FAILED (failures=1)' in output, output
        print('PASS', name, 'precise assertion:', expected, flush=True)


def main():
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    source = (HERE / 'run.py').read_text()
    start = source.index('    def __init__', source.index('class Authority:'))
    end = source.index('    def serve', start)
    control('negative-old-single-pair', source[:start] + OLD_INIT + source[end:],
            'test_P2_real_first_conflict_then_success',
            'P2 first real TCP conflict must retry, not escape')
    needle = '''                for resource in (self.udp, self.tcp):
                    if resource is not None:
                        resource.close()
'''
    assert source.count(needle) == 1
    control('negative-no-failure-close', source.replace(needle, '                pass  # negative control\n'),
            'test_P3_sixteen_conflicts_explicit_cleanup',
            'P3 failed candidates explicitly closed without GC')
    # No file in the working implementation was mutated. Re-run its full entry.
    restored = subprocess.run([sys.executable, str(HERE / 'ports.py')],
                              capture_output=True, text=True, timeout=30)
    output = restored.stdout + restored.stderr
    (EVIDENCE / 'ports-restored.log').write_text(output)
    assert restored.returncode == 0, output
    print('PASS restored ports entry: 6 tests, FD/thread assertions intact', flush=True)


if __name__ == '__main__':
    main()
