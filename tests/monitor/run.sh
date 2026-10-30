#!/usr/bin/env bash
# Exercise monitor actions and edge-triggered T2 ramp-up (docs/03 DNS tiers and docs/04).
set -u
status=0

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UCODE="$ROOT/tests/host/ucode"
DRIVER="$ROOT/tests/monitor/driver.uc"
FIX="$ROOT/tests/fixtures/sample"
STUB_SRC="$ROOT/tests/stubs/daemon-bin"
export AETHER_PROXY_TEST_LOGFILTER="$ROOT/aether-proxy/files/aether-proxy-logfilter.awk"
T="$(mktemp -d)"
CHILD_ROOTS=()

cleanup() {
	local root file pid
	for root in "${CHILD_ROOTS[@]}"; do
		for file in "$root"/xray.pid "$root"/chinadns.pid; do
			[ -f "$file" ] || continue
			read -r pid < "$file"
			if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>>"$T/cleanup.err"; then
				kill -TERM "$pid" 2>>"$T/cleanup.err"
				for _ in {1..15}; do
					if ! kill -0 "$pid" 2>>"$T/cleanup.err"; then break; fi
					sleep 0.1
				done
				if kill -0 "$pid" 2>>"$T/cleanup.err"; then kill -KILL "$pid" 2>>"$T/cleanup.err"; fi
			fi
		done
	done
	if [ "${KEEP_TMP:-0}" = 1 ]; then echo "kept monitor-test temp: $T"; else rm -rf "$T"; fi
}
trap cleanup EXIT INT TERM

mkdir -p "$T/bin" "$T/data" "$T/base" "$T/custom" "$T/enabled-conf"
# Keep shared/golden inputs unchanged; legacy T2 scenarios explicitly opt in here.
cp "$FIX/aetherproxy" "$T/enabled-conf/aetherproxy"
printf "\nconfig dns 'dns'\n\toption direct_dns_enabled '1'\n" >> "$T/enabled-conf/aetherproxy"
cp "$STUB_SRC/"* "$T/bin/"
cp "$ROOT/tests/stubs/daemon-bin/curl" "$T/bin/curl"
cp "$STUB_SRC/xray" "$T/bin/xray-original"
cat > "$T/bin/xray" <<'EOF'
#!/bin/sh
if [ "$1" = run ] && [ "$2" = -c ]; then
	root=${3%/var/run/aether-proxy/current/*}
	if [ -f "$root/xray-listen-delay" ]; then
		sleep 1
	fi
fi
exec "$(dirname "$0")/xray-original" "$@"
EOF
chmod +x "$T/bin/"*
for f in gfwlist chnlist apple; do printf 'example.com\n' > "$T/base/$f.txt"; done
printf '1.0.0.0/8\n' > "$T/base/chnroute4.txt"
printf '91.108.4.0/22\n' > "$T/base/gfw_static4.txt"

make_sysroot() {
	local root="$1" dns_hex
	printf -v dns_hex '%04X' 31053
	mkdir -p "$root/var/etc" "$root/tmp/dnsmasq.d" "$root/proc/net" \
		"$root/sys/class/net/br-lan" "$root/etc/aether-proxy/state" \
		"$root/var/run/aether-proxy/current" "$root/var/lock"
	cat > "$root/var/etc/dnsmasq.conf.cfg01411c" <<'EOF'
interface=br-lan
conf-dir=/tmp/dnsmasq.d,*.conf
EOF
	: > "$root/var/run/aether-proxy/calls.log"
	: > "$root/var/run/aether-proxy/curl-count"
	: > "$root/ip-rules"
	: > "$root/ip-routes"
	: > "$root/conflicts"
	touch "$root/nft-table"
	printf 'local_address rem_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode\n' > "$root/proc/net/tcp"
	printf '  0: 0100007F:7968 00000000:0000 0A 00000000:00000000 00:00000000 00000000 0 0 0\n' >> "$root/proc/net/tcp"
	printf '  1: 0100007F:%s 00000000:0000 0A 00000000:00000000 00:00000000 00000000 0 0 0\n' "$dns_hex" >> "$root/proc/net/tcp"
}

run_case() {
	local name="$1" root="$T/$1" conf="$T/enabled-conf"
	if [[ "$name" = disabled-* ]]; then conf="$FIX"; fi
	make_sysroot "$root"
	CHILD_ROOTS+=("$root")
	STUB_LOG="$root/var/run/aether-proxy/calls.log" \
	SYSROOT="$root" STUB_CURL_COUNT_FILE="$root/var/run/aether-proxy/curl-count" \
	STUB_CURL_FAIL_FROM="${2:-999999}" PATH="$T/bin:$PATH" \
		timeout 30s "$UCODE" "$DRIVER" -- "$name" "$root" "$conf" "$T/data" "$T/base" "$T/custom" "$T/bin" || status=1
}

for scenario in disabled-fallback disabled-no-fallback disabled-t3 disabled-stale-t2 disabled-outage; do
	run_case "$scenario" 1
done
run_case disabled-recover
run_case proxy-tier 2
run_case node-refresh
STUB_NFT_FAIL_ONCE=1 run_case xray-failsafe 999999
for scenario in immediate-proxy immediate-xray immediate-retry immediate-locked; do
	STUB_RESOLVE_FAIL=1 run_case "$scenario" 1
done
python3 "$ROOT/tests/monitor/degrade.py" || status=1
python3 "$ROOT/tests/monitor/applied-context.py" || status=1
python3 "$ROOT/tests/monitor/frozen-paths.py" || status=1
python3 "$ROOT/tests/monitor/debug-logging.py" || status=1
exit "$status"
