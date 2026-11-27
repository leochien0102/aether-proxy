#!/usr/bin/env python3
"""Validate and stage gate-built packages without compiling.

Formal staging uses gate-built packages and reuses published bytes for unchanged
versions. CHANNEL_MANIFEST can override the published manifest source.
"""
import argparse
import ast
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from urllib.parse import urljoin, urlparse
from urllib.request import urlopen
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
# Shared canonical-version rule with the channel publisher.
from channel.build import ARCH_ALL, PACKAGE_NAMES, asset_name, canonical_version
from gate import ARCHES, SDKS, validate_directories


def field(name, key):
	return re.search(r'^' + key + r':=(\S+)$', Path(name + '/Makefile').read_text(), re.M)[1]


CHANNEL_MANIFEST = 'https://github.com/leochien0102/aether-proxy-channel/releases/download/channel-stable/manifest.json'


def fetch_bytes(url):
	"""One injectable transport for manifests and assets; no fallback on errors."""
	try:
		with urlopen(url, timeout=60) as response:
			return response.read()
	except OSError as exc:
		raise ValueError(f'Cannot read published source {url}: {exc}') from exc


def layout(source):
	# Read declarations from the tagged builder without executing release input.
	fields = {node.targets[0].id: ast.literal_eval(node.value) for node in ast.parse(source).body
	          if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name)
	          and node.targets[0].id in ('PACKAGE_NAMES', 'ARCH_ALL')}
	names, arch_all = fields['PACKAGE_NAMES'], fields['ARCH_ALL']
	for seq in (names, arch_all):
		if not isinstance(seq, tuple) or len(seq) != len(set(seq)) or not all(
		        isinstance(n, str) and re.fullmatch(r'[a-z0-9][a-z0-9-]*', n) for n in seq):
			raise ValueError('Invalid tagged package declaration')
	if 'aether-proxy' not in names or not set(arch_all) <= set(names):
		raise ValueError('Invalid tagged package layout')
	return names, arch_all


def reconcile(entries, out, manifest_source=None, fetch=fetch_bytes, arch_all=ARCH_ALL):
	"""Use current published bytes for unchanged versions, including both noarch copies."""
	source = manifest_source or os.environ.get('CHANNEL_MANIFEST', CHANNEL_MANIFEST)
	if not urlparse(source).scheme:
		source = Path(source).resolve().as_uri()
	try:
		manifest = json.loads(fetch(source))
		if not isinstance(manifest, dict) or not isinstance(manifest.get('packages'), dict):
			raise ValueError('manifest must contain a packages object')
		packages = manifest['packages']
		for entry in entries:
			entry['source'] = 'built'
			if entry['package'] not in packages:
				continue
			current = packages[entry['package']]['current']
			if not isinstance(current.get('version'), str) or not current['version']:
				raise ValueError(f'Invalid current version: {entry["package"]}')
			if current['version'] != entry['version']:
				continue
			arch = 'all' if entry['package'] in arch_all else entry['arch']
			asset = current['assets'][arch][entry['format']]
			if asset['url'] != entry['asset']:
				raise ValueError(f'Published asset identity mismatch: {entry["asset"]}')
			digest = asset['sha256']
			if not isinstance(digest, str) or not re.fullmatch(r'[0-9a-f]{64}', digest):
				raise ValueError(f'Invalid published sha256: {entry["package"]} {arch} {entry["format"]}')
			url = urljoin(source, asset['url'])
			content = fetch(url)
			if hashlib.sha256(content).hexdigest() != digest:
				raise ValueError(f'Published sha256 mismatch: {url}')
			if 'size' in asset and len(content) != asset['size']:
				raise ValueError(f'Published size mismatch: {url}')
			(out / entry['asset']).write_bytes(content)
			entry.update(source='published', published_url=url, sha256=digest)
	except (ValueError, KeyError, TypeError, AttributeError, OSError) as exc:
		raise SystemExit(f'Published reconciliation failed ({source}): {exc}') from exc


def main(names, arch_all):
	tag, commit = os.environ['TAG'], os.environ['BUILD_SHA']
	validate_directories(Path('artifacts'))
	version = field('aether-proxy', 'PKG_VERSION')
	release = field('aether-proxy', 'PKG_RELEASE')
	target = f'{version}-r{release}'
	if tag != 'v' + target:
		raise SystemExit('Formal tag/version mismatch')
	if subprocess.check_output(['git', 'rev-parse', 'refs/tags/' + tag + '^{commit}'], text=True).strip() != commit:
		raise SystemExit('Formal tag/commit mismatch')
	out = Path('release-assets')
	out.mkdir()
	entries = []
	for sdk, ext in SDKS:
		for arch in ARCHES:
			directory = Path(f'artifacts/packages-{sdk}-{arch}')
			files = list(directory.rglob('*.' + ext))
			selected = set()
			for name in names:
				prefix = name + ('_' if ext == 'ipk' else '-')
				matches = [p for p in files if p.name.startswith(prefix)]
				if len(matches) != 1:
					raise SystemExit(f'Missing/duplicate {name} {arch} {ext}')
				path = matches[0]
				selected.add(path)
				if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.+~_-]*\.' + ext, path.name) or '..' in path.name:
					raise SystemExit('Unsafe package filename')
				raw = path.name[len(prefix):-4]
				if ext == 'ipk':
					pkg_version, pkg_arch = raw.split('_', 1)
					if pkg_arch != ('all' if name in arch_all else arch):
						raise SystemExit('Package architecture mismatch')
				else:
					pkg_version = raw
				if name != 'luci-i18n-aether-proxy-zh-cn':
					# Real releases render the release suffix as -<release> or
					# -r<release> depending on the build system; the filename version
					# is canonical and both formats must agree (checked below).
					try:
						pkg_version = canonical_version(
							field(name, 'PKG_VERSION'), field(name, 'PKG_RELEASE'), pkg_version)
					except ValueError as exc:
						raise SystemExit(f'Package version mismatch: {path.name}: {exc}')
				elif not re.fullmatch(r'[0-9][A-Za-z0-9.+~_-]*', pkg_version):
					raise SystemExit('Invalid translation version')
				asset = formal_name(name, arch, ext, path.name, arch_all)
				# Same deterministic noarch choice as channel/build.py.
				if name not in arch_all or arch == 'aarch64_generic':
					shutil.copyfile(path, out / asset)
				entries.append(dict(package=name, arch=arch, format=ext, filename=path.name,
									asset=asset, version=pkg_version,
									sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
			if selected != set(files):
				raise SystemExit('Unexpected package artifacts')
	if any(len({e['version'] for e in entries if e['package'] == n}) != 1 for n in names):
		raise SystemExit('Inconsistent package versions across matrix')
	for entry in entries:
		entry['source'] = 'built'
	# M4-17: a package whose version did not change must ship the bytes that are already
	# published, otherwise a reproducible-build difference would force a needless bump.
	reconcile(entries, out, arch_all=arch_all)
	write_formal_metadata(out, commit, {
		e['asset']: e['version'] for e in entries if e['package'] not in arch_all or e['arch'] == 'aarch64_generic'
	}, arch_all, names)


def formal_name(name, arch, ext, filename, arch_all=ARCH_ALL):
	if name not in arch_all and ext == 'apk':
		filename = f'{filename[:-4]}_{arch}.apk'
	return asset_name(filename)


def slot_count(names, arch_all):
	return len({(n, 'all' if n in arch_all else a, f) for n in names for a in ARCHES for _, f in SDKS})


def write_formal_metadata(out, commit, versions, arch_all=ARCH_ALL, names=PACKAGE_NAMES):
	files = sorted(out.iterdir())
	count = slot_count(names, arch_all)
	if len(files) != count or set(versions) != {p.name for p in files} or any(not p.stat().st_size for p in files):
		raise SystemExit(f'Expected exactly {count} nonempty formal package assets')
	assets = {p.name: dict(version=versions[p.name], sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for p in files}
	(out.parent / 'SHA256SUMS').write_text(''.join(f'{a["sha256"]}  {name}\n' for name, a in assets.items()))
	# GitHub normalizes characters such as ~ in asset names. Bind the version as
	# installed by the package manager without adding another Release asset.
	(out.parent / 'release-inventory.json').write_text(json.dumps(dict(commit=commit, assets=assets), sort_keys=True) + '\n')


if __name__ == '__main__':
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument('--expected-count', type=int, help='assert, never override, tagged layout size')
	parser.add_argument('--layout-only', action='store_true', help='print tagged layout size without staging')
	parser.add_argument('--layout-stdin', action='store_true', help='inspect tagged builder source on stdin (layout-only)')
	args = parser.parse_args()
	if args.layout_stdin and not args.layout_only:
		parser.error('--layout-stdin requires --layout-only')
	names, arch_all = layout(sys.stdin.read() if args.layout_stdin else Path('tools/channel/build.py').read_text())
	count = slot_count(names, arch_all)
	if args.expected_count is not None and count != args.expected_count:
		parser.error(f'expected count {args.expected_count} differs from tagged layout {count}')
	if args.layout_only:
		print(count)
	else:
		main(names, arch_all)
