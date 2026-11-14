#!/usr/bin/env python3
"""Select retained gate artifacts for an exact RC commit (docs/08, M4-15).

No build fallback exists here. API errors and incomplete/expired matrices fail closed.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess


MATRIX = {
	f'packages-{sdk}-{arch}': ext
	for sdk, ext in [('24.10.8', 'ipk'), ('25.12.5', 'apk')]
	for arch in ['aarch64_generic', 'x86_64']
}
HINT = '先让门禁通过：在 tag 的同一 SHA 上运行 build.yml，确认四组 packages 和六组 smoke 成功且产物未过期。'


def reject(reason):
	raise ValueError(f'{reason}; {HINT}')


def select_run(runs, sha):
	"""Ignore PR/reusable/failed runs; pick the latest successful trusted event."""
	if not re.fullmatch(r'[0-9a-f]{40}', sha):
		reject('Invalid commit SHA')
	matches = [r for r in runs if r.get('head_sha') == sha
		and r.get('event') in ('push', 'workflow_dispatch')
		and r.get('status') == 'completed' and r.get('conclusion') == 'success'
		and r.get('path') == '.github/workflows/build.yml']
	if not matches:
		reject('No successful build.yml run for SHA ' + sha)
	return max(matches, key=lambda r: (r['run_number'], r.get('run_attempt', 1), r['id']))


def select_artifacts(artifacts, sha, run_id, now=None):
	"""Require exactly four nonexpired artifact IDs bound to the selected run/SHA."""
	now = now or datetime.now(timezone.utc)
	packages = [a for a in artifacts if a['name'].startswith('packages-')]
	if len(packages) != len(MATRIX) or {a['name'] for a in packages} != set(MATRIX):
		reject('Missing/duplicate SDK artifact matrix')
	for artifact in packages:
		binding = artifact.get('workflow_run', {})
		if binding.get('head_sha') != sha or binding.get('id') != run_id:
			reject('Artifact run/SHA mismatch: ' + artifact['name'])
		expires = datetime.fromisoformat(artifact['expires_at'].replace('Z', '+00:00'))
		if artifact.get('expired') is not False or expires <= now or artifact.get('size_in_bytes', 0) <= 0:
			reject('Expired/empty artifact: ' + artifact['name'])
	if len({a['id'] for a in packages}) != len(MATRIX):
		reject('Duplicate artifact IDs')
	return sorted(packages, key=lambda a: a['name'])


def validate_directories(root):
	"""Check download layout before per-package name/version checks in stage.py."""
	if not root.is_dir() or {p.name for p in root.iterdir()} != set(MATRIX):
		reject('Incomplete downloaded SDK matrix')
	for name, ext in MATRIX.items():
		directory = root / name
		if not directory.is_dir() or directory.is_symlink():
			reject('Invalid artifact directory: ' + name)
		files = [p for p in directory.rglob('*') if p.suffix in ('.ipk', '.apk')]
		# One artifact per built package: proxy, luci, i18n, xray, chinadns-ng, aether-dns.
		if len(files) != 6 or any(p.suffix != '.' + ext or not p.is_file() or p.is_symlink() for p in files):
			reject('Missing/extra package files: ' + name)


def api_pages(repo, endpoint, key):
	# --slurp preserves every page: a busy repository must not lose older successful runs.
	command = ['gh', 'api', '--paginate', '--slurp', f'repos/{repo}/{endpoint}']
	pages = json.loads(subprocess.check_output(command, text=True))
	return [item for page in pages for item in page[key]]


def main():
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument('--sha', required=True)
	parser.add_argument('--repo', required=True)
	args = parser.parse_args()
	try:
		runs = api_pages(args.repo, f'actions/workflows/build.yml/runs?head_sha={args.sha}&per_page=100',
			'workflow_runs')
		run = select_run(runs, args.sha)
		artifacts = api_pages(args.repo, f'actions/runs/{run["id"]}/artifacts?per_page=100', 'artifacts')
		selected = select_artifacts(artifacts, args.sha, run['id'])
	except (ValueError, KeyError, subprocess.CalledProcessError) as exc:
		raise SystemExit(f'Gate artifact selection failed: {exc}; {HINT}') from exc
	print(f'run_id={run["id"]}')
	print('artifact_ids=' + ','.join(str(a['id']) for a in selected))


if __name__ == '__main__':
	main()
