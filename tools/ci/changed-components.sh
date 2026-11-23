#!/bin/sh
# Map a commit range to the packages an automatic push/PR must build (component-scoped CI).
# Usage: changed-components.sh <base> <head>
# Empty output means this range changes nothing that needs a package build.
set -eu
base=$1
head=$2
[ "$base" != "0000000000000000000000000000000000000000" ] || base=$(git rev-parse "$head^" 2>/dev/null || echo "")
files=$(git diff --name-only "$base" "$head" 2>/dev/null || true)
[ -n "$files" ] || files=$(git show --pretty='' --name-only "$head")
packages=""
add() { case " $packages " in *" $1 "*) ;; *) packages="${packages:+$packages }$1" ;; esac; }
# The smoke matrix installs aether-xray, chinadns-ng, aether-proxy, luci-app and its i18n
# together, and release-assets expects the same five; an app/LuCI change therefore has to
# (re)build the unchanged components too, or smoke fails on missing artifacts (2026-11-16,
# release 1.2.0 gate: "exactly one chinadns-ng artifact (found 0)").
add_smoke_packages() {
	add aether-proxy; add luci-app-aether-proxy; add aether-xray; add chinadns-ng; add aether-dns;
}
for f in $files; do
	case "$f" in
		aether-xray/*) add aether-xray ;;
		aether-proxy/*) add_smoke_packages ;;
		aether-dns/*) add aether-dns ;;
		chinadns-ng/*) add chinadns-ng ;;
		luci-app-aether-proxy/*) add_smoke_packages ;;
		# These inputs change what every build and smoke run exercises.
		.github/workflows/build.yml|tools/ci/*|tests/ci/smoke*|tests/fixtures/sample/*)
			add_smoke_packages ;;
	esac
done
printf '%s\n' "$packages"
