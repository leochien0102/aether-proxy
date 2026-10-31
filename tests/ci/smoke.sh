#!/bin/sh
# T9.3: installation-only matrix from docs/11; package/CLI contracts from docs/01 and docs/10.
# Run only on a disposable OpenWrt rootfs: this installs and removes all five packages.
# Usage: sh smoke.sh <package-dir> <repo-dir> [--test-root <fake-root>]
# Host tests prepare <package-dir>/smoke-golden using smoke-host.py. No CI env is needed.
set -u

if [ "$#" -ne 2 ] && [ "$#" -ne 4 ]; then
	echo 'Usage: smoke.sh <package-dir> <repo-dir> [--test-root <fake-root>]' >&2
	exit 2
fi
packages=$1
repo=$2
root=''
if [ "$#" -eq 4 ]; then
	[ "$3" = --test-root ] && [ -d "$4" ] && [ "$4" != / ] || exit 2
	root=$4
fi
pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; }

# Keep full command output (especially dependency solver errors) and always report its exit code.
run() {
	printf '+ '; printf '%s ' "$@"; printf '\n'
	if "$@"; then
		return 0
	else
		rc=$?
		printf 'FAIL  command exit %s: %s\n' "$rc" "$*"
		return "$rc"
	fi
}

# Containers have no procd/ubus/kernel support. Suppress ALL maintainer scripts rather than
# mocking fw4 or allowing dependency hooks to start services. Dependency resolution stays on.
# TODO(design): maintainer-script behaviour is outside this installation-only matrix;
# confirm it separately on a real OpenWrt device, not by enabling hooks in the container.
if command -v opkg >/dev/null 2>&1; then
	manager=opkg
	ext=ipk
elif command -v apk >/dev/null 2>&1; then
	manager=apk
	ext=apk
else
	bad 'package manager available'
	exit 1
fi
# apk v3 takes --no-scripts as a commit option of add/del, after the applet; update rejects it.
pm() {
	if [ "$manager" = opkg ]; then
		run opkg --offline-root "${root:-/}" "$@"
	else
		applet=$1
		shift
		case "$applet" in
			add|del) run apk --root "${root:-/}" "$applet" --no-scripts "$@" ;;
			*) run apk --root "${root:-/}" "$applet" "$@" ;;
		esac
	fi
}

# Select exactly one artifact for each package: silently choosing an old build hides failures.
set --
for name in aether-xray chinadns-ng aether-proxy luci-app-aether-proxy luci-i18n-aether-proxy-zh-cn; do
	count=0
	for file in "$packages"/"$name"_*.$ext "$packages"/"$name"-*.$ext; do
		[ -f "$file" ] || continue
		# Require a numeric version so auxiliary files with a similar prefix cannot be installed.
		base=${file##*/}
		case "$base" in
			"$name"_[0-9]*.ipk|"$name"-[0-9]*.apk) count=$((count + 1)); selected=$file ;;
		esac
	done
	if [ "$count" -ne 1 ]; then
		bad "exactly one $name artifact (found $count)"
		exit 1
	fi
	set -- "$@" "$selected"
done
# An unbooted rootfs has an empty /tmp, which /var points into: opkg cannot create its lock.
mkdir -p "$root/var/lock" || exit 1
pm update || exit 1
if [ "$manager" = opkg ]; then
	pm install "$@" || exit 1
else
	pm add --allow-untrusted "$@" || exit 1
fi
ok 'five packages installed with dependencies'

work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
ap="$root/usr/bin/aether-proxy"
version=$(awk -F ':=' '/^PKG_VERSION:=/ { print $2 }' "$repo/aether-proxy/Makefile")
release=$(awk -F ':=' '/^PKG_RELEASE:=/ { print $2 }' "$repo/aether-proxy/Makefile")
if output=$("$ap" version 2>&1); then
	printf '%s\n' "$output"
	case "$output" in
		*"aether-proxy $version-r$release"*) ok 'version contains package version' ;;
		*) bad 'version contains package version' ;;
	esac
else
	rc=$?
	printf '%s\n' "$output"
	bad "version exits 0 (got $rc)"
fi

file_present() {
	if [ -s "$root$1" ]; then ok "file $1"; else bad "file $1"; fi
}
for file in /usr/bin/aether-proxy /etc/init.d/aether-proxy /etc/config/aetherproxy \
	/usr/share/aether-proxy/logfilter.awk \
	/usr/share/nftables.d/chain-pre/input/30-aether-proxy.nft \
	/usr/share/rpcd/ucode/aetherproxy.uc /usr/share/rpcd/acl.d/luci-app-aether-proxy.json \
	/usr/share/luci/menu.d/luci-app-aether-proxy.json; do
	file_present "$file"
done
for name in gfwlist chnlist apple chnroute4 gfw_static4; do
	file_present "/usr/share/aether-proxy/data/$name.txt"
done
for key in "$repo"/aether-proxy/files/keys/*; do
	[ -f "$key" ] || { bad 'repository channel key exists'; continue; }
	file_present "/etc/aether-proxy/keys/${key##*/}"
done
for view in overview nodes access rules updates logs advanced; do
	file_present "/www/luci-static/resources/view/aether-proxy/$view.js"
done

# T9.7: each matrix cell exercises its own firmware awk, not a host-generated result.
if command -v mkfifo >/dev/null 2>&1 && mkfifo "$work/log.fifo" && [ -p "$work/log.fifo" ]; then
	ok 'mkfifo available and creates FIFO'
else
	bad 'mkfifo available and creates FIFO'
fi
awk 'BEGIN { for (i = 1; i <= 500; i++) printf "100 sample %d\n", i }' > "$work/flood"
awk 'BEGIN { for (i = 1; i <= 20; i++) printf "sample %d\n", i }' > "$work/filtered.expected"
printf '%s\n' 'aether-proxy: smoke output rate limited, dropped 480 lines between 00:01:40 and 00:01:40' \
	>> "$work/filtered.expected"
if TZ=UTC0 awk -v test_clock=1 -v name=smoke -f "$root/usr/share/aether-proxy/logfilter.awk" \
	"$work/flood" > "$work/filtered" && cmp -s "$work/filtered.expected" "$work/filtered"; then
	ok 'firmware awk limits 500 lines to 20 plus EOF summary'
else
	bad 'firmware awk limits 500 lines to 20 plus EOF summary'
fi

# docs/05 "校验规则" rule 1: a node is required only when enabled=1. The packaged
# default is disabled, so both it and tests/fixtures/sample must pass (exit 0).
check_config() {
	label=$1
	shift
	if "$ap" check --no-precheck --run-dir "$work/run" "$@"; then
		ok "$label check exits 0"
	else
		rc=$?
		bad "$label check exits 0 (got $rc)"
	fi
}
check_config default
check_config sample --confdir "$repo/tests/fixtures/sample"

# Host goldens use the same installed paths. Render does not write to run-dir; leave its
# default unchanged so path-bearing chinadns output can be compared byte-for-byte.
for kind in nft chinadns dnsmasq xray; do
	case "$kind" in
		nft) file=aether-proxy.nft ;;
		chinadns|dnsmasq) file=$kind.conf ;;
		xray) file=xray.json ;;
	esac
	if "$ap" render "$kind" --confdir "$repo/tests/fixtures/sample" > "$work/$file"; then
		if [ -s "$packages/smoke-golden/$file" ] && cmp -s "$packages/smoke-golden/$file" "$work/$file"; then
			ok "render $kind matches host golden"
		else
			bad "render $kind matches host golden"
		fi
	else
		rc=$?
		bad "render $kind exits 0 (got $rc)"
	fi
done
# M10 regression (T10.7, T10.4): data status counts lines with one busybox `grep -H -c` call,
# and components is a new subcommand; both must work on every firmware's busybox/ucode.
# The line count is checked against an awk count of the same rule (05 list-file parsing).
if "$ap" data status --json ${root:+--sys-root "$root"} > "$work/data.json"; then
	want=$(awk '{ sub(/^[ \t\r]+/, "") } $0 != "" && substr($0, 1, 1) != "#"' \
		"$root/usr/share/aether-proxy/data/chnlist.txt" | wc -l)
	got=$(ucode -l fs -e "let v = json(fs.readfile('$work/data.json')); print(v?.ok === true && length(v.items) == 5 ? v.items.chnlist.lines : 'bad');")
	if [ "$got" = "$want" ] && [ "$want" -gt 0 ]; then
		ok "data status counts chnlist lines ($got)"
	else
		cat "$work/data.json"
		bad "data status counts chnlist lines (got $got, want $want)"
	fi
else
	rc=$?
	cat "$work/data.json"
	bad "data status exits 0 (got $rc)"
fi
if "$ap" components --json > "$work/components.json"; then
	got=$(ucode -l fs -e "let v = json(fs.readfile('$work/components.json')); print(v?.ok === true && type(v.components?.xray) == 'object' && type(v.components?.['chinadns-ng']) == 'object' ? 'ok' : 'bad');")
	if [ "$got" = ok ]; then ok 'components reports xray and chinadns-ng'; else cat "$work/components.json"; bad 'components reports xray and chinadns-ng'; fi
else
	rc=$?
	cat "$work/components.json"
	bad "components exits 0 (got $rc)"
fi
if run ucode -S "$root/usr/share/rpcd/ucode/aetherproxy.uc"; then
	ok 'rpcd plugin loads without rpcd'
else
	bad 'rpcd plugin loads without rpcd'
fi

if [ "$manager" = opkg ]; then
	pm remove luci-i18n-aether-proxy-zh-cn luci-app-aether-proxy aether-proxy aether-xray chinadns-ng || exit 1
else
	pm del luci-i18n-aether-proxy-zh-cn luci-app-aether-proxy aether-proxy aether-xray chinadns-ng || exit 1
fi
for file in /usr/bin/aether-proxy /etc/init.d/aether-proxy; do
	if [ ! -e "$root$file" ] && [ ! -L "$root$file" ]; then
		ok "removed $file"
	else
		bad "removed $file"
	fi
done
# opkg --offline-root removes the module files but may keep the emptied directories (first CI
# run, 24.10): what matters is that no module file is left behind.
left=$(find "$root/usr/share/ucode/aetherproxy" ! -type d 2>/dev/null)
if [ -z "$left" ]; then
	ok 'removed /usr/share/ucode/aetherproxy files'
else
	printf '%s\n' "$left"
	bad 'removed /usr/share/ucode/aetherproxy files'
fi
printf 'smoke: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
