#!/usr/bin/env python3
"""Validate and stage gate-built packages without compiling.

Formal staging uses gate-built packages and reuses published bytes for unchanged
versions. CHANNEL_MANIFEST can override the published manifest source.
"""
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
from channel.build import ARCH_ALL, asset_name, canonical_version
from gate import validate_directories


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


def reconcile(entries, out, manifest_source=None, fetch=fetch_bytes):
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
			arch = 'all' if entry['package'] in (
				'aether-proxy', 'luci-app-aether-proxy', 'luci-i18n-aether-proxy-zh-cn') else entry['arch']
			asset = current['assets'][arch][entry['format']]
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


def main():
	tag, commit = os.environ['TAG'], os.environ['BUILD_SHA']
	validate_directories(Path('artifacts'))
	version = field('aether-proxy', 'PKG_VERSION')
	release = field('aether-proxy', 'PKG_RELEASE')
	target = f'{version}-r{release}'
	if tag != 'v' + target:
		raise SystemExit('Formal tag/version mismatch')
	if subprocess.check_output(['git', 'rev-parse', 'refs/tags/' + tag + '^{commit}'], text=True).strip() != commit:
		raise SystemExit('Formal tag/commit mismatch')
	names = ['aether-proxy', 'luci-app-aether-proxy', 'luci-i18n-aether-proxy-zh-cn', 'aether-xray', 'chinadns-ng',
		'aether-dns']
	out = Path('release-assets')
	out.mkdir()
	entries = []
	for sdk, ext in [('24.10.8', 'ipk'), ('25.12.5', 'apk')]:
		for arch in ['aarch64_generic', 'x86_64']:
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
					if pkg_arch != ('all' if name in names[:3] else arch):
						raise SystemExit('Package architecture mismatch')
				else:
					pkg_version = raw
				if name != names[2]:
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
				asset = formal_name(name, arch, ext, path.name)
				# Same deterministic noarch choice as channel/build.py.
				if name not in ARCH_ALL or arch == 'aarch64_generic':
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
	reconcile(entries, out)
	write_formal_metadata(out, commit, {
		e['asset']: e['version'] for e in entries if e['package'] not in ARCH_ALL or e['arch'] == 'aarch64_generic'
	})


def formal_name(name, arch, ext, filename):
	if name not in ARCH_ALL and ext == 'apk':
		filename = f'{filename[:-4]}_{arch}.apk'
	return asset_name(filename)


def write_formal_metadata(out, commit, versions):
	files = sorted(out.iterdir())
	if len(files) != 18 or set(versions) != {p.name for p in files} or any(not p.stat().st_size for p in files):
		raise SystemExit('Expected exactly 18 nonempty formal package assets')
	assets = {p.name: dict(version=versions[p.name], sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for p in files}
	(out.parent / 'SHA256SUMS').write_text(''.join(f'{a["sha256"]}  {name}\n' for name, a in assets.items()))
	# GitHub normalizes characters such as ~ in asset names. Bind the version as
	# installed by the package manager without adding a nineteenth Release asset.
	(out.parent / 'release-inventory.json').write_text(json.dumps(dict(commit=commit, assets=assets), sort_keys=True) + '\n')


if __name__ == '__main__':
	if sys.argv[1:]:
		raise SystemExit('usage: stage.py')
	main()
