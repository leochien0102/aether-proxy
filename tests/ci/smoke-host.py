#!/usr/bin/env python3
"""T9.3 host coverage for the ash smoke runner; never installs packages or uses Docker.

The fake root contains package-source files and executable stubs. Real pinned host ucode
checks default/sample configurations, generates the four goldens and loads the rpcd plugin.
Optional --golden-dir exports that same oracle for the six CI containers.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[2]
UCODE = REPO / 'tests/host/ucode'
ARTIFACTS = {'nft': 'aether-proxy.nft', 'chinadns': 'chinadns.conf',
	'dnsmasq': 'dnsmasq.conf', 'xray': 'xray.json'}
PACKAGES = ('aether-proxy', 'luci-app-aether-proxy', 'luci-i18n-aether-proxy-zh-cn')


def expect(condition, name, detail=''):
	if not condition:
		raise AssertionError(f'{name}\n{detail}')
	print(f'PASS  {name}')


def execute(argv, **kwargs):
	return subprocess.run([str(arg) for arg in argv], cwd=REPO, text=True,
		stdout=subprocess.PIPE, stderr=subprocess.STDOUT, **kwargs)


def executable(path, text):
	path.parent.mkdir(parents=True, exist_ok=True)
	path.write_text(text)
	path.chmod(0o755)


def copy_file(root, source, target):
	out = root / target.lstrip('/')
	out.parent.mkdir(parents=True, exist_ok=True)
	shutil.copy2(REPO / source, out)


def make_root(root):
	files = {
		'aether-proxy/src/aether-proxy': '/usr/bin/aether-proxy',
		'aether-proxy/files/aether-proxy.init': '/etc/init.d/aether-proxy',
		'aether-proxy/files/aether-proxy.config': '/etc/config/aetherproxy',
		'aether-proxy/files/30-aether-proxy.nft':
			'/usr/share/nftables.d/chain-pre/input/30-aether-proxy.nft',
	}
	for source, target in files.items():
		copy_file(root, source, target)
	for path in (REPO / 'aether-proxy/files/data').glob('*.txt'):
		copy_file(root, path, '/usr/share/aether-proxy/data/' + path.name)
	for path in (REPO / 'aether-proxy/files/keys').iterdir():
		copy_file(root, path, '/etc/aether-proxy/keys/' + path.name)
	shutil.copytree(REPO / 'luci-app-aether-proxy/root', root, dirs_exist_ok=True)
	shutil.copytree(REPO / 'luci-app-aether-proxy/htdocs', root / 'www', dirs_exist_ok=True)
	(root / 'usr/share/ucode/aetherproxy').mkdir(parents=True)


# Package-manager stubs enforce safe options and simulate uninstall; any unexpected command
# fails, so a regression to dependency bypasses or service/nft invocations cannot pass silently.
PM_STUB = '''#!/usr/bin/env python3
import os
from pathlib import Path
import shutil
import sys
root = Path(os.environ['STUB_ROOT'])
a = sys.argv[1:]
manager = Path(sys.argv[0]).name
with open(root / 'commands', 'a') as log:
    log.write(manager + ' ' + ' '.join(a) + '\\n')
if manager == 'opkg':
    assert a[:2] == ['--offline-root', str(root)], a
else:
    assert a[:3] == ['--root', str(root), '--no-scripts'], a
assert '--nodeps' not in a and '--force-depends' not in a, a
command = a[2] if manager == 'opkg' else a[3]
if command == 'update':
    sys.exit(0)
if command in ('install', 'add'):
    assert len([s for s in a if s.endswith(('.apk', '.ipk'))]) == 3, a
    if manager == 'apk':
        assert '--allow-untrusted' in a, a
    if os.environ['STUB_FAULT'] == 'install':
        print('solver: missing dependency example-dependency')
        sys.exit(17)
    (root / 'installed').write_text('yes')
    sys.exit(0)
assert command in ('remove', 'del'), a
assert a[-3:] == ['luci-i18n-aether-proxy-zh-cn', 'luci-app-aether-proxy', 'aether-proxy'], a
for file in ('usr/bin/aether-proxy', 'etc/init.d/aether-proxy'):
    (root / file).unlink()
if os.environ['STUB_FAULT'] != 'uninstall':
    shutil.rmtree(root / 'usr/share/ucode/aetherproxy')
'''

CLI_STUB = '''#!/usr/bin/env python3
import os
from pathlib import Path
import sys
root = Path(os.environ['STUB_ROOT'])
assert (root / 'installed').exists()
a = sys.argv[1:]
fault = os.environ['STUB_FAULT']
if a == ['version']:
    version = '0.0.0-wrong' if fault == 'version-content' else os.environ['STUB_VERSION']
    print('aether-proxy ' + version)
    sys.exit(19 if fault == 'version' else 0)
if a[0] == 'check':
    assert '--no-precheck' in a, a
    sample = '--confdir' in a
    sys.exit(2 if fault == ('sample' if sample else 'default') else 0)
assert a[0] == 'render' and a[1] in ('nft', 'chinadns', 'dnsmasq', 'xray'), a
assert a[2:] == ['--confdir', os.environ['STUB_REPO'] + '/tests/fixtures/sample'], a
file = {'nft': 'aether-proxy.nft', 'chinadns': 'chinadns.conf',
        'dnsmasq': 'dnsmasq.conf', 'xray': 'xray.json'}[a[1]]
sys.stdout.buffer.write((Path(os.environ['STUB_GOLDEN']) / file).read_bytes())
if fault == 'render' and a[1] == 'chinadns':
    print('wrong rendering')
'''


def version_from_makefile():
	values = dict(line.split(':=', 1) for line in
		(REPO / 'aether-proxy/Makefile').read_text().splitlines() if ':=' in line)
	return values['PKG_VERSION'] + '-r' + values['PKG_RELEASE']


def host_oracle(work):
	golden = work / 'golden'
	result = execute([UCODE, REPO / 'tests/ci/smoke-golden.uc', '--', REPO, golden])
	expect(result.returncode == 0, 'four real host goldens generated', result.stdout)
	for kind, file in ARTIFACTS.items():
		expect((golden / file).stat().st_size > 0, f'host golden {kind} is nonempty')
	expect('/var/run/aether-proxy/boot.txt' in (golden / 'chinadns.conf').read_text(),
		'golden uses installed paths without output normalization')
	default = work / 'default'
	default.mkdir()
	shutil.copy2(REPO / 'aether-proxy/files/aether-proxy.config', default / 'aetherproxy')
	for label, conf in [('default', default), ('sample', REPO / 'tests/fixtures/sample')]:
		result = execute([UCODE, '-S', REPO / 'aether-proxy/src/aether-proxy', '--',
			'check', '--no-precheck', '--confdir', conf, '--baseline-dir',
			REPO / 'aether-proxy/files/data', '--data-dir', golden / 'empty',
			'--custom-dir', golden / 'empty', '--run-dir', work / 'run'])
		expect(result.returncode == 0, f'real host {label} check exits 0', result.stdout)
	return golden


def run_scenario(work, golden, manager, fault):
	dirname = f'{manager}-{fault or "pass"}'
	case = work / dirname
	root = case / 'root'
	make_root(root)
	packages = case / 'packages'
	packages.mkdir()
	for name in PACKAGES:
		file = f'{name}_0.2.0-r6_all.ipk' if manager == 'opkg' else f'{name}-0.2.0-r6.apk'
		(packages / file).touch()
	shutil.copytree(golden, packages / 'smoke-golden')
	bin_dir = case / 'bin'
	executable(bin_dir / manager, PM_STUB)
	executable(root / 'usr/bin/aether-proxy', CLI_STUB)
	# The plugin is really executed using the pinned interpreter, not accepted by a no-op stub.
	executable(bin_dir / 'ucode', '#!/bin/sh\nexec "' + str(UCODE) + '" "$@"\n')
	if fault == 'missing':
		(root / 'usr/share/aether-proxy/data/apple.txt').unlink()
	elif fault == 'plugin':
		(root / 'usr/share/rpcd/ucode/aetherproxy.uc').write_text('invalid syntax !!!')
	elif fault == 'artifact':
		next(packages.glob('aether-proxy*')).unlink()
	env = dict(os.environ, PATH=str(bin_dir) + ':' + os.environ['PATH'],
		STUB_ROOT=str(root), STUB_GOLDEN=str(golden), STUB_FAULT=fault,
		STUB_REPO=str(REPO), STUB_VERSION=version_from_makefile(), TMPDIR=str(case))
	result = execute(['sh', REPO / 'tests/ci/smoke.sh', packages, REPO, '--test-root', root], env=env)
	return result, root


def verify_scenarios(work, golden):
	failures = {
		'missing': 'FAIL  file /usr/share/aether-proxy/data/apple.txt',
		'render': 'FAIL  render chinadns matches host golden',
		'default': 'FAIL  default check exits 0 (got 2)',
		'sample': 'FAIL  sample check exits 0 (got 2)',
		'plugin': 'FAIL  rpcd plugin loads without rpcd',
		'uninstall': 'FAIL  removed /usr/share/ucode/aetherproxy',
		'version': 'FAIL  version exits 0 (got 19)',
		'version-content': 'FAIL  version contains package version',
		'install': 'solver: missing dependency example-dependency',
		'artifact': 'FAIL  exactly one aether-proxy artifact (found 0)',
	}
	for manager in ('opkg', 'apk'):
		result, root = run_scenario(work, golden, manager, '')
		expect(result.returncode == 0 and '0 failed' in result.stdout,
			f'{manager}: complete smoke PASS', result.stdout)
		for kind in ARTIFACTS:
			expect(f'PASS  render {kind} matches host golden' in result.stdout,
				f'{manager}: {kind} compared byte-for-byte', result.stdout)
		expect('PASS  rpcd plugin loads without rpcd' in result.stdout,
			f'{manager}: real rpcd plugin load', result.stdout)
		commands = (root / 'commands').read_text()
		expect('update' in commands and ('remove' if manager == 'opkg' else 'del') in commands,
			f'{manager}: index, dependency install and uninstall commands recorded', commands)
		for fault, message in failures.items():
			result, root = run_scenario(work, golden, manager, fault)
			expect(result.returncode != 0 and message in result.stdout,
				f'{manager}: {fault} FAIL detected', result.stdout)
			if fault in ('missing', 'render'):
				expect(not (root / 'usr/bin/aether-proxy').exists(),
					f'{manager}: {fault} still uninstalls packages', result.stdout)


def main():
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument('--golden-dir', type=Path)
	args = parser.parse_args()
	result = execute(['sh', '-n', REPO / 'tests/ci/smoke.sh'])
	expect(result.returncode == 0, 'smoke.sh sh syntax', result.stdout)
	if shutil.which('busybox'):
		result = execute(['busybox', 'ash', '-n', REPO / 'tests/ci/smoke.sh'])
		expect(result.returncode == 0, 'smoke.sh BusyBox ash syntax', result.stdout)
	else:
		print('WARN  BusyBox unavailable; ash syntax needs CI verification')
	with tempfile.TemporaryDirectory(prefix='smoke-host-', dir=REPO / 'tests') as temp:
		work = Path(temp)
		golden = host_oracle(work)
		verify_scenarios(work, golden)
		if args.golden_dir:
			expect(not args.golden_dir.exists(), 'golden export directory is new')
			shutil.copytree(golden, args.golden_dir)
	print('smoke-host: all assertions passed')


if __name__ == '__main__':
	main()
