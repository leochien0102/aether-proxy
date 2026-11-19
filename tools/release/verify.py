#!/usr/bin/env python3
"""Read-only release verification and channel-backed formal staging."""
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from tempfile import TemporaryDirectory

from gate import api_pages
from stage import ARCH_ALL, formal_name, write_formal_metadata

APP = 'leochien0102/aether-proxy'
CHANNEL = 'leochien0102/aether-proxy-channel'
ARCHES = ('aarch64_generic', 'x86_64')
FORMATS = ('ipk', 'apk')
NAMES = (*ARCH_ALL, 'aether-xray', 'chinadns-ng', 'aether-dns')
FORMAL = r'v[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+'
RC = r'v[0-9]+\.[0-9]+\.[0-9]+(?:-r[0-9]+)?-rc[1-9][0-9]*'


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


def published(repo, tag, prerelease=False):
    release = api(repo, 'releases/tags/' + tag)
    if (release['tag_name'] != tag or release['draft'] is not False
            or release['prerelease'] is not prerelease):
        raise ValueError(f'Draft/prerelease mismatch: {tag}')
    return release


def download(repo, tag, directory, *patterns):
    gh('release', 'download', tag, '-R', repo, '-D', str(directory),
       *(arg for pattern in patterns for arg in ('-p', pattern)))


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_rc(repo, tag, directory, all_assets=False):
    if not re.fullmatch(RC, tag):
        raise ValueError('Expected an RC tag')
    release = published(repo, tag, prerelease=True)
    commit = commit_for(repo, tag)
    # A successful candidate run binds the published manifest to the exact gate-selected commit.
    runs = api_pages(repo, f'actions/workflows/release-candidate.yml/runs?head_sha={commit}&event=push&per_page=100',
                     'workflow_runs')
    if not any(r['head_sha'] == commit and r['head_branch'] == tag and r['event'] == 'push'
               and r['conclusion'] == 'success' for r in runs):
        raise ValueError(f'No successful release-candidate run for {tag} at {commit}')
    download(repo, tag, directory, *(() if all_assets else ('rc-manifest.json', 'SHA256SUMS')))
    manifest = json.loads((directory / 'rc-manifest.json').read_text())
    target = manifest['target_tag']
    if (manifest['schema'] != 1 or manifest['rc_tag'] != tag or manifest['commit'] != commit
            or not re.fullmatch(FORMAL, target)
            or not re.fullmatch(re.escape(target.split('-r')[0]) + r'(?:-r' + target.split('-r')[1] + r')?-rc[1-9][0-9]*', tag)):
        raise ValueError('RC tag/commit/target mismatch')
    sums = {}
    for line in (directory / 'SHA256SUMS').read_text().splitlines():
        match = re.fullmatch(r'([0-9a-f]{64})  ([A-Za-z0-9._-]+)', line)
        if not match or match[2] in sums:
            raise ValueError('Invalid RC checksum list')
        sums[match[2]] = match[1]
    if (set(sums) | {'SHA256SUMS'} != {a['name'] for a in release['assets']}
            or sums.get('rc-manifest.json') != digest(directory / 'rc-manifest.json')):
        raise ValueError('RC checksum list does not bind the published assets')
    if all_assets and any(digest(directory / name) != value for name, value in sums.items()):
        raise ValueError('RC asset checksum mismatch')
    entries = manifest['assets']
    matrix = {(n, a, f) for n in NAMES for a in ARCHES for f in FORMATS}
    if len(entries) != 24 or {(e['package'], e['arch'], e['format']) for e in entries} != matrix:
        raise ValueError('Invalid RC package matrix')
    for e in entries:
        if (not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.+~_-]*\.' + e['format'], e['filename'])
                or '..' in e['filename'] or sums.get(e['asset']) != e['sha256']):
            raise ValueError('Unbound RC package')
    return manifest


def gate_only_rc(manifest):
    return all(e.get('source') == 'built' for e in manifest['assets'])


def rc_inventory(manifest, field):
    return {formal_name(e['package'], e['arch'], e['format'], e['filename']): e[field]
            for e in manifest['assets'] if e['package'] not in ARCH_ALL or e['arch'] == ARCHES[0]}


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


def channel_stage(repo, tag, commit):
    with TemporaryDirectory() as tmp:
        root = Path(tmp)
        manifest = stable_manifest(root)
        if not matches_version(manifest, tag):
            print('mode=direct')
            return
        selected = {a['url']: a['sha256'] for _, _, _, a in channel_packages(manifest)}
        # A version match is not a provenance check: require a matching immutable RC
        # whose candidate workflow succeeded for this exact formal tag commit.
        candidates = [r['tag_name'] for page in json.loads(gh('api', '--paginate', '--slurp',
                      f'repos/{repo}/releases?per_page=100')) for r in page if r['prerelease'] and not r['draft']
                      and re.fullmatch(RC, r['tag_name']) and r['tag_name'].rsplit('-rc', 1)[0] in
                      (tag, tag.split('-r')[0])]
        for candidate in candidates:
            if commit_for(repo, candidate) != commit:
                continue
            dest = root / candidate
            rc = read_rc(repo, candidate, dest)
            if rc['target_tag'] == tag and gate_only_rc(rc) and rc_inventory(rc, 'sha256') == selected:
                break
        else:
            raise ValueError('Matching stable version has no byte-identical RC for the formal tag commit')
        out = Path('release-assets')
        download(CHANNEL, 'channel-stable', out, *sorted(selected))
        if {p.name: digest(p) for p in out.iterdir()} != selected:
            raise ValueError('Stable manifest/package checksum mismatch')
        write_formal_metadata(out, commit, rc_inventory(rc, 'version'))
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


def compare(repo, tag, rc_tag=None):
    with TemporaryDirectory() as tmp:
        root = Path(tmp)
        release = published(repo, tag)
        out = root / 'formal'
        download(repo, tag, out, '*.ipk', '*.apk')
        hashes = {p.name: digest(p) for p in out.iterdir()}
        if rc_tag:
            expected = rc_inventory(read_rc(repo, rc_tag, root / 'rc', all_assets=True), 'sha256')
            if len(expected) != 18 or hashes != expected:
                raise ValueError('Formal Release/RC package checksum mismatch')
            for name, value in sorted(hashes.items()):
                print(f'{value}  {name}  (Release = RC)')
        else:
            manifest = stable_manifest(root)
            if not matches_version(manifest, tag):
                raise ValueError('Stable current version does not match the Release')
            assets = {(n, a, f): item for n, a, f, item in channel_packages(manifest)}
            expected = {a['url']: a['sha256'] for a in assets.values()}
            if len(expected) != 18 or hashes != expected:
                raise ValueError('Formal Release/stable checksum mismatch')
            with TemporaryDirectory() as channel:
                download(CHANNEL, 'channel-stable', channel, *sorted(expected))
                if {p.name: digest(p) for p in Path(channel).iterdir()} != expected:
                    raise ValueError('Published channel assets do not match its manifest')
            for name in NAMES:
                item = manifest['packages'][name]
                print(f'{name}: current={item["current"]["version"]} previous={(item.get("previous") or {}).get("version", "-")}')
                for arch in ARCHES:
                    for fmt in FORMATS:
                        a = assets[name, 'all' if name in ARCH_ALL else arch, fmt]
                        print(f'  {arch}/{fmt}: {a["sha256"]}  {a["url"]}  (Release = channel)')
        print(release['html_url'])


if __name__ == '__main__':
    action, repo, tag, *rest = sys.argv[1:]
    try:
        if action in ('rc', 'rc-gate-only'):
            with TemporaryDirectory() as tmp:
                m = read_rc(repo, tag, Path(tmp))
                if action == 'rc-gate-only' and not gate_only_rc(m):
                    raise ValueError('RC contains historically reconciled packages; publish a gate-only RC')
                print(m['commit'], m['target_tag'])
        elif action == 'channel-stage':
            channel_stage(repo, tag, *rest)
        elif action == 'compare':
            compare(repo, tag, *rest)
        elif action == 'check-direct':
            check_direct()
        elif action == 'stable-matches':
            with TemporaryDirectory() as tmp:
                print('yes' if matches_version(stable_manifest(Path(tmp)), tag) else 'no')
        else:
            raise ValueError(f'Unknown verification action: {action}')
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as exc:
        raise SystemExit(f'Release verification failed: {exc}') from exc
