#!/usr/bin/env python3
"""Validate/stage RC bytes and reconcile published versions (docs/08, M4-15/M4-17).

Never build packages or replace published bytes with a same-version rebuild.
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
# Shared canonical-version rule with channel promote (fetched from the same commit).
from channel.build import canonical_version
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
	if not re.fullmatch(r'v' + re.escape(version) + r'(?:-r' + re.escape(release) + r')?-rc[1-9][0-9]*', tag):
		raise SystemExit('RC tag/version mismatch')
	if subprocess.check_output(['git', 'rev-parse', tag + '^{commit}'], text=True).strip() != commit:
		raise SystemExit('RC tag/commit mismatch')
	names = ['aether-proxy', 'luci-app-aether-proxy', 'luci-i18n-aether-proxy-zh-cn', 'aether-xray', 'chinadns-ng',
		'aether-dns']
	out = Path('rc-assets')
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
				# Keep both SDK noarch builds, even when their bytes differ. GitHub-safe names.
				asset = arch + '--' + re.sub(r'[^A-Za-z0-9._-]', '.', path.name)
				shutil.copyfile(path, out / asset)
				entries.append(dict(package=name, arch=arch, format=ext, filename=path.name,
									asset=asset, version=pkg_version,
									sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
			if selected != set(files):
				raise SystemExit('Unexpected package artifacts')
	if any(len({e['version'] for e in entries if e['package'] == n}) != 1 for n in names):
		raise SystemExit('Inconsistent package versions across matrix')
	# Reconcile before writing any manifest/SHA256SUMS: failure cannot produce a promotable RC.
	reconcile(entries, out)
	# A bridge chain is opt-in and reviewed: present at bridges/compatibility.json in the
	# tagged commit it rides the prerelease verbatim (promote verifies its assets); the
	# terminal step must be the built aether-proxy, or the file is stale for this RC.
	reviewed = Path('bridges/compatibility.json')
	if reviewed.is_file():
		try:
			chain = json.loads(reviewed.read_text())
		except json.JSONDecodeError as exc:
			raise SystemExit(f'bridges/compatibility.json is not valid JSON: {exc}')
		steps = chain.get('aether-proxy', {}).get('steps') if isinstance(chain, dict) else None
		built = next(e['version'] for e in entries if e['package'] == names[0])
		if not isinstance(steps, list) or not steps or (steps[-1] or {}).get('version') != built:
			raise SystemExit(f'bridges/compatibility.json terminal step must be the built aether-proxy {built}')
		shutil.copyfile(reviewed, out / 'compatibility.json')
	manifest = dict(schema=1, rc_tag=tag, commit=commit, version=version,
					target_tag='v' + target, assets=entries)
	if reviewed.is_file():
		manifest['compatibility'] = 'compatibility.json'
	(out / 'rc-manifest.json').write_text(json.dumps(manifest, sort_keys=True, indent=2) + '\n')
	sums = ''.join(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.name + '\n'
				   for p in sorted(out.iterdir()))
	(out / 'SHA256SUMS').write_text(sums)


if __name__ == '__main__':
	main()
