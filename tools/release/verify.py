#!/usr/bin/env python3
"""Read-only release verification and formal Release/stable byte checks."""
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from tempfile import TemporaryDirectory

from stage import ARCH_ALL

CHANNEL = 'leochien0102/aether-proxy-channel'
ARCHES = ('aarch64_generic', 'x86_64')
FORMATS = ('ipk', 'apk')
NAMES = (*ARCH_ALL, 'aether-xray', 'chinadns-ng', 'aether-dns')
FORMAL = r'v[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+'


def gh(*args):
    return subprocess.check_output(['gh', *args], text=True)


def api(repo, endpoint):
    return json.loads(gh('api', f'repos/{repo}/{endpoint}'))


def commit_for(repo, tag):
    obj = api(repo, 'git/ref/tags/' + tag)['object']
    for _ in range(10):
        if obj['type'] == 'commit':
            return obj['sha']
        if obj['type'] != 'tag':
            break
        obj = api(repo, 'git/tags/' + obj['sha'])['object']
    raise ValueError(f'Tag does not resolve to a commit: {tag}')


def published(repo, tag):
    release = api(repo, 'releases/tags/' + tag)
    if (release['tag_name'] != tag or release['draft'] is not False
            or release['prerelease'] is not False):
        raise ValueError(f'Draft/prerelease mismatch: {tag}')
    return release


def download(repo, tag, directory, *patterns):
    gh('release', 'download', tag, '-R', repo, '-D', str(directory),
       *(arg for pattern in patterns for arg in ('-p', pattern)))


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def stable_only(value):
    if isinstance(value, dict):
        if 'prerelease' in value and value['prerelease'] is not False:
            raise ValueError('channel-stable must not contain prerelease entries')
        for child in value.values():
            stable_only(child)
    elif isinstance(value, list):
        for child in value:
            stable_only(child)


def stable_manifest(directory):
    # Fail closed on API/download errors; only a successful release listing can prove absence.
    if not any(r['tag_name'] == 'channel-stable' for page in json.loads(gh('api', '--paginate', '--slurp',
               f'repos/{CHANNEL}/releases?per_page=100')) for r in page):
        return None
    published(CHANNEL, 'channel-stable')
    download(CHANNEL, 'channel-stable', directory, 'manifest.json')
    manifest = json.loads((directory / 'manifest.json').read_text())
    stable_only(manifest)
    if manifest['schema'] != 2 or not isinstance(manifest['packages'], dict):
        raise ValueError('Invalid stable manifest')
    return manifest


def matches_version(manifest, tag):
    return manifest is not None and manifest['packages']['aether-proxy']['current']['version'] in (
        tag[1:], tag[1:].replace('-r', '-'))


def channel_packages(manifest):
    for name in NAMES:
        release = manifest['packages'][name]['current']
        arches = ('all',) if name in ARCH_ALL else ARCHES
        if set(release['assets']) != set(arches):
            raise ValueError(f'Invalid architectures for {name}')
        for arch in arches:
            if set(release['assets'][arch]) != set(FORMATS):
                raise ValueError(f'Invalid formats for {name}/{arch}')
            for fmt in FORMATS:
                asset = release['assets'][arch][fmt]
                if (not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*\.' + fmt, asset['url'])
                        or '..' in asset['url'] or not re.fullmatch('[0-9a-f]{64}', asset['sha256'])):
                    raise ValueError(f'Invalid asset for {name}/{arch}/{fmt}')
                yield name, arch, fmt, asset


def publication_route(repo, tag, commit):
    with TemporaryDirectory() as tmp:
        root = Path(tmp)
        manifest = stable_manifest(root)
        if not matches_version(manifest, tag):
            print('mode=direct')
            return
        # A matching stable version permits an idempotent rerun, not a new
        # Release assembled from mutable channel assets.
        if commit_for(repo, tag) != commit:
            raise ValueError('Formal tag commit changed')
        compare_bytes(repo, tag, root, manifest, log=sys.stderr)
        print('mode=channel')


def check_direct():
    """Fail before creating a Release that cannot enter stable unchanged."""
    with TemporaryDirectory() as tmp:
        manifest = stable_manifest(Path(tmp))
        if manifest is None:
            return
        local = {p.name: digest(p) for p in Path('release-assets').iterdir()}
        for entry in manifest['packages'].values():
            for key in ('current', 'previous'):
                for formats in ((entry.get(key) or {}).get('assets') or {}).values():
                    for asset in formats.values():
                        name = asset['url']
                        if name in local and local[name] != asset['sha256']:
                            raise ValueError(f'Gate bytes conflict with published package {name}; bump its package release')


def compare_bytes(repo, tag, root, manifest, log):
    release = published(repo, tag)
    if not matches_version(manifest, tag):
        raise ValueError('Stable current version does not match the Release')
    assets = {(n, a, f): item for n, a, f, item in channel_packages(manifest)}
    expected = {a['url']: a['sha256'] for a in assets.values()}
    names = {a['name'] for a in release['assets']}
    if len(expected) != 18 or names - {'SHA256SUMS'} != set(expected):
        raise ValueError('Formal Release/stable package set mismatch')
    out = root / 'formal'
    download(repo, tag, out, '*.ipk', '*.apk')
    if {p.name: digest(p) for p in out.iterdir()} != expected:
        raise ValueError('Formal Release/stable checksum mismatch')
    channel = root / 'stable'
    download(CHANNEL, 'channel-stable', channel, *sorted(expected))
    if {p.name: digest(p) for p in channel.iterdir()} != expected:
        raise ValueError('Published channel assets do not match its manifest')
    for name in NAMES:
        item = manifest['packages'][name]
        print(f'{name}: current={item["current"]["version"]} previous={(item.get("previous") or {}).get("version", "-")}',
              file=log)
        for arch in ARCHES:
            for fmt in FORMATS:
                asset = assets[name, 'all' if name in ARCH_ALL else arch, fmt]
                print(f'  {arch}/{fmt}: {asset["sha256"]}  {asset["url"]}  (Release = channel)', file=log)
    print(release['html_url'], file=log)


def compare(repo, tag):
    with TemporaryDirectory() as tmp:
        root = Path(tmp)
        compare_bytes(repo, tag, root, stable_manifest(root), log=sys.stdout)


if __name__ == '__main__':
    action, repo, tag, *rest = sys.argv[1:]
    try:
        if not re.fullmatch(FORMAL, tag):
            raise ValueError('Expected a formal vVERSION-rN tag')
        if action == 'publication-route':
            publication_route(repo, tag, *rest)
        elif action == 'compare':
            if rest:
                raise ValueError('compare accepts only the app repository and formal tag')
            compare(repo, tag)
        elif action == 'check-direct':
            check_direct()
        elif action == 'stable-matches':
            with TemporaryDirectory() as tmp:
                print('yes' if matches_version(stable_manifest(Path(tmp)), tag) else 'no')
        else:
            raise ValueError(f'Unknown verification action: {action}')
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as exc:
        raise SystemExit(f'Release verification failed: {exc}') from exc
