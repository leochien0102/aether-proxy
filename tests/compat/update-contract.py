#!/usr/bin/env python3
"""Offline dependency/ordered-migration contract; no product behavior is mocked."""
import argparse
import ast
import copy
import importlib.util
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = Path(__file__).with_name('update-contract.json')
DOC = ROOT / 'docs/08-updates.md'


def hard_dependencies(text):
    block = re.search(r'define Package/aether-proxy\n(.*?)\nendef', text, re.S)[1]
    logical = block.replace('\\\n', ' ')
    value = re.search(r'^\s*DEPENDS\s*:?=([^\n]*)', logical, re.M)[1]
    # Conditional +CONFIG:package is still a potential hard dependency.
    return {token[1:].split(':')[-1] for token in value.split('#')[0].split()
            if token.startswith('+')}


def managed_packages():
    # Read, never execute/import the publisher. New channel packages automatically
    # enter this check; no fixed aether-xray/chinadns-ng-only allowlist.
    tree = ast.parse((ROOT / 'tools/channel/build.py').read_text())
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and
                                               t.id == 'PACKAGE_NAMES' for t in node.targets):
            return set(ast.literal_eval(node.value))
    raise ValueError('channel PACKAGE_NAMES not found')


def version(value):
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-r\d+)?', value):
        raise ValueError('invalid contract version: ' + value)
    base, _, release = value.partition('-r')
    return tuple(map(int, base.split('.'))) + (int(release or 0),)


def validate_chain(chain, required):
    steps = chain['compatibility']['aether-proxy']['steps']
    versions = [s['version'] for s in steps]
    # A separately frozen itinerary detects deletion even if min_from is edited
    # to conceal the gap (versions need not be numerically consecutive).
    if versions != required:
        raise ValueError('missing, unordered or duplicate bridge step')
    previous = chain['from']
    for step in steps:
        if step['min_from'] != previous or version(step['version']) <= version(previous):
            raise ValueError('bridge min_from does not join strictly increasing chain')
        if not step.get('assets'):
            raise ValueError('bridge assets missing')
        for formats in step['assets'].values():
            if not formats:
                raise ValueError('bridge formats missing')
            for fmt, asset in formats.items():
                if fmt not in ('ipk', 'apk') or not re.fullmatch(r'[A-Za-z0-9._-]+', asset['url']) or asset['url'] in ('.', '..'):
                    raise ValueError('invalid bridge asset')
                if not re.fullmatch(r'[a-f0-9]{64}', asset['sha256']) or asset['size'] <= 0:
                    raise ValueError('invalid bridge hash/size')
        previous = step['version']
    if previous != chain['target']:
        raise ValueError('bridge target not reached')
    return versions


def next_step(chain, current, required):
    versions = validate_chain(chain, required)
    if current == chain['target']:
        return None
    if current == chain['from']:
        return versions[0]
    if current not in versions:
        raise ValueError('client not on bridge chain')
    return versions[versions.index(current) + 1]


def resolve_dependencies(deps, managed, provides):
    # Virtual names are not in the channel inventory: resolve BEFORE intersection,
    # or deleting a mapping would silently remove a hard dependency from coverage.
    for virtual, package in provides.items():
        if package not in managed:
            raise ValueError(f'provides: {virtual} points to unregistered package: {package}')
    if provides.get('dns-engine') != 'aether-dns':
        raise ValueError('provides: dns-engine must resolve to managed aether-dns')
    return {provides.get(dep, dep) for dep in deps}


def manual_dependencies(client, provides):
    manual = set(client.get('manual_packages', []))
    # Frozen clients require chinadns-ng by name. Only its actual PROVIDES
    # metadata can prove that this manual prerequisite satisfies the virtual dep.
    for package in list(manual):
        makefile = ROOT / package / 'Makefile'
        if makefile.is_file():
            declared = re.search(r'^\s*PROVIDES:=(.*)$', makefile.read_text(), re.M)
            if declared:
                manual.update(provides[v] for v in declared[1].split() if v in provides)
    return manual


def check_closure(name, client, deps, managed, provides):
    resolved = resolve_dependencies(deps, managed, provides)
    missing = resolved & managed - set(client['known_packages'])
    unregistered = missing - manual_dependencies(client, provides)
    if unregistered:
        raise ValueError(f'{name}: managed hard dependencies outside client closure: ' +
                         ', '.join(sorted(unregistered)))
    return missing


def validate_contract(data, deps, managed, docs=None):
    if data['contract_version'] != 1 or data['wire_schema'] != 2:
        raise ValueError('contract v1 / wire schema 2 must remain frozen')
    current = re.search(r'^PKG_VERSION:=(.*)$', (ROOT / 'aether-proxy/Makefile').read_text(), re.M)[1]
    if data['support_window'][0] != current or len(data['support_window']) != 2:
        raise ValueError('support window must be current + previous formal release')
    if version(data['support_window'][1]) >= version(current):
        raise ValueError('invalid previous release')
    clients = data['clients']
    for supported in data['support_window']:
        if clients[supported]['route'] == 'manual-only':
            raise ValueError('supported client cannot be manual-only')
    for name, client in clients.items():
        missing = check_closure(name, client, deps, managed, data.get('provides', {}))
        migration = set(client.get('manual_packages', []))
        if name not in data['support_window'] and client['route'] != 'manual-only':
            raise ValueError(f'{name}: older clients must be manual-only')
        if client['route'] not in ('direct', 'manual-prerequisite', 'manual-only', 'bridge'):
            raise ValueError('unknown route')
        if client['route'] == 'direct' and missing:
            raise ValueError(f'{name}: direct route has missing dependencies')
        if client['route'] == 'bridge':
            chain = data['bridges'][name]
            validate_chain(chain, data['required_steps'][name])
        if docs is not None:
            row = '| ' + ' | '.join([name, client['route'],
                                      ', '.join(sorted(migration)) or '—']) + ' |'
            if row not in docs:
                raise ValueError('docs migration row missing: ' + row)
    old = clients['0.3.1']
    old_packages = {'xray-core', 'aether-proxy', 'luci-app-aether-proxy',
                    'luci-i18n-aether-proxy-zh-cn'}
    if old['route'] != 'manual-only' or set(old['known_packages']) != old_packages:
        raise ValueError('0.3.1 frozen closure/manual boundary changed')


class ContractTests(unittest.TestCase):
    def setUp(self):
        self.data = json.loads(FIXTURE.read_text())
        self.deps = hard_dependencies((ROOT / 'aether-proxy/Makefile').read_text())
        self.managed = managed_packages()
        self.chain = self.data['bridge_example']
        self.required = self.data['bridge_required_steps']

    def test_repository_contract_and_docs(self):
        validate_contract(self.data, self.deps, self.managed, DOC.read_text())

    def test_virtual_dependency_negative_cases(self):
        for mutation in ('delete-provides', 'unknown-aether-dns', 'unregistered-provider'):
            with self.subTest(mutation=mutation):
                data = copy.deepcopy(self.data)
                if mutation == 'delete-provides':
                    del data['provides']
                elif mutation == 'unknown-aether-dns':
                    data['clients']['1.0.0']['known_packages'].remove('aether-dns')
                else:
                    data['provides']['dns-engine'] = 'unregistered-engine'
                with self.assertRaises(ValueError) as caught:
                    validate_contract(data, self.deps, self.managed)
                print(f'PASS negative {mutation}: {caught.exception}')

    def test_unregistered_dependency_fails_for_supported_clients(self):
        for client in self.data['support_window']:
            data = copy.deepcopy(self.data)
            data['clients'][client]['known_packages'].remove('aether-xray')
            with self.assertRaisesRegex(ValueError, 'aether-xray'):
                validate_contract(data, self.deps, self.managed)
        with self.assertRaisesRegex(ValueError, 'future-managed'):
            validate_contract(self.data, self.deps | {'future-managed'}, self.managed | {'future-managed'})

    def test_support_window_and_documented_manual_exceptions(self):
        for mutation in ('window', 'old-route', 'docs', 'manual-package', 'frozen-closure'):
            with self.subTest(mutation=mutation):
                data = copy.deepcopy(self.data)
                docs = DOC.read_text()
                if mutation == 'window':
                    data['support_window'].append('0.3.1')
                elif mutation == 'old-route':
                    data['clients']['0.3.1']['route'] = 'bridge'
                elif mutation == 'docs':
                    docs = docs.replace('| 0.3.1 | manual-only | aether-xray, chinadns-ng |', '')
                elif mutation == 'manual-package':
                    data['clients']['0.6.2']['manual_packages'] = []
                else:
                    data['clients']['0.3.1']['known_packages'].append('aether-xray')
                with self.assertRaises((ValueError, KeyError)):
                    validate_contract(data, self.deps, self.managed, docs)

    def test_wire_schema_and_current_known_packages(self):
        const = (ROOT / 'aether-proxy/src/lib/const.uc').read_text()
        known = set(re.findall(r"'([^']+)'", re.search(r'UPDATE_PACKAGES = \[(.*?)\]', const)[1]))
        engines = set(self.data['provides'].values())
        self.assertEqual(known | engines,
                         set(self.data['clients'][self.data['support_window'][0]]['known_packages']))
        self.assertEqual(known, set(self.data['clients']['0.7.0']['known_packages']))
        update = (ROOT / 'aether-proxy/src/lib/update.uc').read_text()
        self.assertIn('manifest.schema != 2', update)
        tree = ast.parse((ROOT / 'tools/channel/build.py').read_text())
        schemas = [ast.literal_eval(value) for node in ast.walk(tree) if isinstance(node, ast.Dict)
                   for key, value in zip(node.keys, node.values)
                   if isinstance(key, ast.Constant) and key.value == 'schema']
        self.assertEqual(schemas, [self.data['wire_schema']])

    def test_system_packages_are_not_update_dependencies(self):
        validate_contract(self.data, self.deps | {'kmod-example', 'ip-full'}, self.managed)
        resolved = resolve_dependencies(self.deps, self.managed, self.data['provides'])
        self.assertIn('aether-dns', resolved & self.managed)
        self.assertIn('dns-engine', self.deps)
        self.assertNotIn('ip-full', self.deps & self.managed)
        self.assertEqual(hard_dependencies('define Package/aether-proxy\n DEPENDS:= +FLAG:future-managed +ip-full # +ignored\nendef'), {'future-managed', 'ip-full'})

    def test_031_cannot_claim_direct_upgrade(self):
        self.assertEqual(self.data['clients']['0.3.1']['route'], 'manual-only')
        data = copy.deepcopy(self.data)
        data['clients']['0.3.1']['route'] = 'direct'
        with self.assertRaises(ValueError):
            validate_contract(data, self.deps, self.managed)
        data = copy.deepcopy(self.data)
        data['clients']['0.3.1']['manual_packages'] = []
        with self.assertRaisesRegex(ValueError, 'aether-dns, aether-xray'):
            validate_contract(data, self.deps, self.managed)

    def test_publisher_enforces_frozen_bridge_itinerary(self):
        spec = importlib.util.spec_from_file_location('channel_build', ROOT / 'tools/channel/build.py')
        publisher = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(publisher)
        packages = {'aether-proxy': {'current': {'version': self.chain['target']}}}
        publisher.validate_compatibility(self.chain['compatibility'], packages)
        broken = copy.deepcopy(self.chain['compatibility'])
        steps = broken['aether-proxy']['steps']
        del steps[1]
        steps[1]['min_from'] = steps[0]['version']
        with self.assertRaisesRegex(ValueError, 'required_steps'):
            publisher.validate_compatibility(broken, packages)

    def test_only_next_bridge_is_selectable(self):
        for current, expected in zip(['0.6.3'] + self.required, self.required + [None]):
            self.assertEqual(next_step(self.chain, current, self.required), expected)
        with self.assertRaises(ValueError):
            next_step(self.chain, '0.6.5', self.required)

    def test_invalid_bridge_chains(self):
        for mutation in ('missing', 'rejoined-gap', 'order', 'duplicate', 'min_from', 'assets', 'hash', 'target'):
            with self.subTest(mutation=mutation):
                chain = copy.deepcopy(self.chain)
                steps = chain['compatibility']['aether-proxy']['steps']
                if mutation in ('missing', 'rejoined-gap'):
                    del steps[1]
                    if mutation == 'rejoined-gap':
                        steps[1]['min_from'] = steps[0]['version']
                elif mutation == 'order':
                    steps.reverse()
                elif mutation == 'duplicate':
                    steps.insert(1, copy.deepcopy(steps[0]))
                elif mutation == 'min_from':
                    steps[1]['min_from'] = '0.6.3'
                elif mutation == 'assets':
                    steps[1]['assets'] = {}
                elif mutation == 'hash':
                    steps[1]['assets']['all']['ipk']['sha256'] = 'bad'
                else:
                    chain['target'] = '0.6.9'
                with self.assertRaises(ValueError):
                    validate_chain(chain, self.required)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--reproduce', action='store_true', help='remove migration registrations; expected failure')
    args = parser.parse_args()
    if args.reproduce:
        data = json.loads(FIXTURE.read_text())
        # Exercise the same closure validator with migration exemptions removed.
        data['clients']['0.3.1']['manual_packages'] = []
        try:
            check_closure('0.3.1', data['clients']['0.3.1'],
                          hard_dependencies((ROOT / 'aether-proxy/Makefile').read_text()),
                          managed_packages(), data.get('provides', {}))
        except ValueError as error:
            raise SystemExit(str(error))
        raise SystemExit(0)
    unittest.main(argv=[__file__], verbosity=2)
