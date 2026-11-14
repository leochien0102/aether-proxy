#!/bin/sh
# Map a commit range to the packages a push must build (component-scoped CI).
# Usage: changed-components.sh <base> <head>
# Empty output means this push changes nothing that needs a package build.
set -eu
base=$1
head=$2
[ "$base" != "0000000000000000000000000000000000000000" ] || base=$(git rev-parse "$head^" 2>/dev/null || echo "")
files=$(git diff --name-only "$base" "$head" 2>/dev/null || true)
[ -n "$files" ] || files=$(git show --pretty='' --name-only "$head")
packages=""
add() { case " $packages " in *" $1 "*) ;; *) packages="${packages:+$packages }$1" ;; esac; }
for f in $files; do
	case "$f" in
		aether-xray/*) add aether-xray ;;
		aether-proxy/*) add aether-proxy ;;
		aether-dns/*) add aether-dns ;;
		chinadns-ng/*) add chinadns-ng ;;
		luci-app-aether-proxy/*) add luci-app-aether-proxy ;;
		# These inputs change what every build and smoke run exercises.
		.github/workflows/build.yml|tools/ci/*|tests/ci/smoke*|tests/fixtures/sample/*)
			add aether-proxy; add luci-app-aether-proxy; add aether-xray; add chinadns-ng; add aether-dns ;;
	esac
done
printf '%s\n' "$packages"
