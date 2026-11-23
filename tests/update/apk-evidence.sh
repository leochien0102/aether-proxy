#!/usr/bin/env bash
# Real apk-tools 3.0.5 evidence; no host database, network, or package scripts.
# APK_BIN=/path/to/real/apk tests/update/apk-evidence.sh [--capture]
# KEEP_EVIDENCE=1 retains the temporary command transcripts and isolated roots.
set -euo pipefail
export LC_ALL=C TZ=UTC
mode=compare
case "${1:-}" in
	'') ;;
	--capture) mode=capture; shift ;;
	*) printf 'usage: %s [--capture]\n' "$0" >&2; exit 2 ;;
esac
[ "$#" -eq 0 ] || { printf 'unexpected arguments\n' >&2; exit 2; }
: "${APK_BIN:?set APK_BIN to a real apk-tools 3.0.5 executable}"
[ -x "$APK_BIN" ] || { printf 'APK_BIN is not executable\n' >&2; exit 2; }
APK_BIN=$(realpath "$APK_BIN")
fixtures=$(cd -- "$(dirname -- "$0")" && pwd)/fixtures/apk-provides
work=$(mktemp -d "${TMPDIR:-/tmp}/apk-evidence.XXXXXXXX")
cleanup() {
	if [ "${KEEP_EVIDENCE:-0}" = 1 ]; then
		printf 'Evidence retained: %s\n' "$work"
	else
		rm -rf -- "$work"
	fi
}
trap cleanup EXIT
mkdir -p "$work/logs" "$work/files" "$work/packages"
: > "$work/repositories"

# Every apk invocation has separate, unmodified stdout/stderr/rc and shell-quoted
# argv. version.stdout identifies the tool for the entire transcript directory.
run() {
	local label=$1 rc=0 argv
	shift
	printf -v argv '%q ' "$@"
	argv=${argv% }
	printf '%s\n' "$argv" > "$work/logs/$label.command"
	"$@" > "$work/logs/$label.stdout" 2> "$work/logs/$label.stderr" || rc=$?
	printf '%s\n' "$rc" > "$work/logs/$label.rc"
	{
		printf '\n$ %s\n' "$argv"
		printf '%s\n' '--- stdout'; cat "$work/logs/$label.stdout"
		printf '%s\n' '--- stderr'; cat "$work/logs/$label.stderr"
		printf '%s\n' "--- rc: $rc"
	} | tee -a "$work/transcript.txt"
}
require_rc() {
	local actual
	actual=$(< "$work/logs/$1.rc")
	[ "$actual" = "$2" ] || { printf '%s: expected rc %s, got %s\n' "$1" "$2" "$actual" >&2; exit 1; }
}
run version "$APK_BIN" --version
require_rc version 0
grep -Eq '^apk-tools 3\.0\.5,' "$work/logs/version.stdout" || {
	printf 'This evidence is pinned to apk-tools 3.0.5\n' >&2; exit 1;
}
for command in mkpkg mkndx query add list; do
	run "help-$command" "$APK_BIN" "$command" --help
done

make_package() {
	local label=$1 name=$2 provides=$3 version=$4
	local -a metadata=(--info "name:$name" --info "version:$version")
	metadata+=(
		--info description:apk-installed-query-evidence --info license:MIT)
	if [ -n "$provides" ]; then metadata+=(--info "provides:$provides"); fi
	run "mkpkg-$label" "$APK_BIN" --root "$work/build-root" --no-network \
		--repositories-file "$work/repositories" mkpkg --files "$work/files" \
		"${metadata[@]}" --output "$work/packages/$label.apk"
	require_rc "mkpkg-$label" 0
}
mkdir -p "$work/build-root"
make_package aether-dns aether-dns dns-engine=1.0.0 1.0.0-r1
make_package chinadns-ng chinadns-ng dns-engine 2025.08.09-r1
make_package no-provides aether-dns '' 1.0.0-r1

install_package() {
	local label=$1
	shift
	mkdir -p "$work/$label"
	run "add-$label" "$APK_BIN" --root "$work/$label" --usermode --initdb \
		--no-network --allow-untrusted --force-non-repository \
		--repositories-file "$work/repositories" add "$@"
	require_rc "add-$label" 0
}
install_package aether-dns "$work/packages/aether-dns.apk"
install_package chinadns-ng "$work/packages/chinadns-ng.apk"
install_package no-provides "$work/packages/no-provides.apk"
# Empty database without any repository candidate.
install_package absent

# The same empty installed state, but with a real offline repository candidate.
install_package repository-only
run mkndx "$APK_BIN" --root "$work/build-root" --no-network --allow-untrusted \
	--repositories-file "$work/repositories" mkndx \
	--output "$work/packages/Packages.adb" "$work/packages/aether-dns.apk"
require_rc mkndx 0
printf 'ndx %s\n' "$work/packages/Packages.adb" > "$work/local-repositories"
for source in repositories installed; do
	label=repository-candidate
	if [ "$source" = installed ]; then label=repository-only; fi
	run "$label" "$APK_BIN" --root "$work/repository-only" --no-network \
		--allow-untrusted --repositories-file "$work/local-repositories" \
		query --from "$source" --format json --fields name,version,provides aether-dns
	require_rc "$label" 0
done

query_installed() {
	local label=$1 name=$2
	run "$label" "$APK_BIN" --root "$work/$label" --no-network \
		--repositories-file "$work/repositories" query --from installed \
		--format json --fields name,version,provides "$name"
}
query_installed aether-dns aether-dns
query_installed chinadns-ng chinadns-ng
query_installed no-provides aether-dns
query_installed absent aether-dns
# Preserve the original list interface verbatim for legacy replay comparisons.
for name in aether-dns chinadns-ng; do
	run "$name-list" "$APK_BIN" --root "$work/$name" --no-network \
		--repositories-file "$work/repositories" list -I "$name"
	require_rc "$name-list" 0
done
# This path must not be created: failed database access is not an empty result.
query_installed failure aether-dns
require_rc aether-dns 0
require_rc chinadns-ng 0
require_rc no-provides 0
require_rc absent 0
require_rc failure 99

# Assert meaning independently before accepting or comparing golden output.
python3 - "$work/logs" <<'PY'
import json
from pathlib import Path
import sys
logs = Path(sys.argv[1])
for label, name, version, provides in (
    ('aether-dns', 'aether-dns', '1.0.0-r1', ['dns-engine=1.0.0']),
    ('repository-candidate', 'aether-dns', '1.0.0-r1', ['dns-engine=1.0.0']),
    ('chinadns-ng', 'chinadns-ng', '2025.08.09-r1', ['dns-engine']),
    ('no-provides', 'aether-dns', '1.0.0-r1', []),
):
    data = json.loads((logs / (label + '.stdout')).read_text())
    assert len(data) == 1, (label, data)
    package = data[0]
    assert package['name'] == name, (label, package)
    assert package['version'] == version, (label, package)
    assert package.get('provides', []) == provides, (label, package)
    assert not (logs / (label + '.stderr')).read_bytes(), label
for label in ('absent', 'repository-only'):
    assert json.loads((logs / (label + '.stdout')).read_text()) == [], label
    assert not (logs / (label + '.stderr')).read_bytes(), label
assert not (logs / 'failure.stdout').read_bytes()
assert (logs / 'failure.stderr').read_bytes()
PY

labels=(version aether-dns chinadns-ng aether-dns-list chinadns-ng-list no-provides absent failure repository-candidate repository-only)
if [ "$mode" = capture ]; then mkdir -p "$fixtures"; fi
for label in "${labels[@]}"; do
	for suffix in stdout stderr rc; do
		if [ "$mode" = capture ]; then
			cp "$work/logs/$label.$suffix" "$fixtures/$label.$suffix"
		else
			diff -u "$fixtures/$label.$suffix" "$work/logs/$label.$suffix"
		fi
	done
done
printf '\nPASS: real apk installed-query evidence (%s, six scenarios)\n' "$mode" | tee -a "$work/transcript.txt"
# Temporary absolute paths are intentionally preserved for audit, not compared.
if [ "$mode" = capture ]; then cp "$work/transcript.txt" "$fixtures/transcript.txt"; fi
