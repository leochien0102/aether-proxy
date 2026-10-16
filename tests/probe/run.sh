#!/usr/bin/env bash
# Probe scenarios for docs/07 「实现细节」 (2026-10-16) and docs/tasks/m8.md T8.5.
#
# Scenarios 1-2 run in-process through tests/probe/driver.uc (the production
# recorder is wrapped, and probe.json is snapshotted after every write).
# Scenarios 2-4 also run through the real CLI entry point: partial runs keep
# old results, `probe nodes --json` equals the final file, a damaged probe.json
# counts as empty, and `probe results` is read-only with the documented default.
# Everything stays in a mktemp directory; TCP connections only touch the local
# loopback listener and TEST-NET-1 (192.0.2.1, RFC 5737, never routed).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UCODE="$ROOT/tests/host/ucode"
ENTRY="$ROOT/aether-proxy/src/aether-proxy"
DRIVER="$ROOT/tests/probe/driver.uc"
JGET="$ROOT/tests/cli/jget.uc"

T="$(mktemp -d "$ROOT/tests/probe/tmp.XXXXXX")"
PID_OPEN=''
PID_CLOSED=''

cleanup() {
	for pid in "$PID_OPEN" "$PID_CLOSED"; do
		[ -n "$pid" ] || continue
		kill "$pid" 2>/dev/null || :
		wait "$pid" 2>/dev/null || :
	done
	if [ "${KEEP_TMP:-0}" = 1 ]; then echo "kept probe-test temp: $T"; else rm -rf "$T"; fi
}
trap cleanup EXIT INT TERM

pass=0
fail=0

ok() { pass=$((pass + 1)); echo "PASS  $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1"; [ $# -gt 1 ] && echo "      $2"; }
expect() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected '$2', got '$3'"; }
jget() { "$UCODE" "$JGET" -- "$1"; }
ap() { "$UCODE" -S "$ENTRY" -- "$@"; }

# ucode-level deep comparison of two JSON files
jdeq() { # jdeq <json-file-a> <json-file-b>
	"$UCODE" -e '
		import * as fs from "fs";
		function deep(x, y) {
			if (type(x) != type(y))
				return false;
			if (type(x) == "object") {
				if (join("|", sort(keys(x))) != join("|", sort(keys(y))))
					return false;
				for (let k in sort(keys(x)))
					if (!deep(x[k], y[k]))
						return false;
				return true;
			}
			if (type(x) == "array") {
				if (length(x) != length(y))
					return false;
				for (let i = 0; i < length(x); i++)
					if (!deep(x[i], y[i]))
						return false;
				return true;
			}
			return x === y;
		}
		let a = json(fs.readfile(ARGV[0]));
		let b = json(fs.readfile(ARGV[1]));
		print(deep(a, b) ? "same" : "different", "\n");
	' -- "$1" "$2"
}

# A loopback TCP listener that accepts and immediately closes connections.
# Prints the bound port; the pid is stored in the named variable given first.
start_listener() { # start_listener <out-pid-var> <out-port-var>
	local pid_var="$1" port_var="$2" port_file="$T/port.$$.txt"
	"$UCODE" -e '
		import * as socket from "socket";
		import * as fs from "fs";
		let server = socket.create(socket.AF_INET, socket.SOCK_STREAM);
		if (server == null || !server.bind({ address: "127.0.0.1", port: 0 }) || !server.listen(32))
			exit(1);
		let bound = server.sockname();
		let fp = fs.open(ARGV[0], "w");
		if (fp == null)
			exit(1);
		fp.write(`${bound.port}\n`);
		fp.close();
		while (true) {
			let peer = server.accept();
			if (peer != null)
				peer.close();
		}
	' -- "$port_file" > /dev/null 2>&1 &
	local pid=$!
	for _ in {1..50}; do
		[ -s "$port_file" ] && break
		sleep 0.05
	done
	printf -v "$pid_var" '%s' "$pid"
	printf -v "$port_var" '%s' "$(cat "$port_file")"
	rm -f "$port_file"
}

start_listener PID_OPEN OPEN_PORT
start_listener PID_CLOSED CLOSED_PORT
# The second listener's port is only needed as a known-closed loopback port:
# stop it before probing, nothing else rebinds it within the test run.
kill "$PID_CLOSED" 2>/dev/null || :
wait "$PID_CLOSED" 2>/dev/null || :

[ -n "$OPEN_PORT" ] && ok "open listener bound a loopback port" || bad "open listener bound a loopback port"
[ -n "$CLOSED_PORT" ] && ok "closed listener bound a loopback port" || bad "closed listener bound a loopback port"

# confdir fixture with the three driver nodes (open, closed, TEST-NET).
make_conf() {
	local dir="$1"
	mkdir -p "$dir"
	{
		echo "config main 'main'"
		echo "	option enabled '0'"
		echo "config probe 'probe'"
		echo "	option node_timeout '1'"
		echo "	option node_concurrency '8'"
		for id in n_00000000000000000000000000000001 n_00000000000000000000000000000002 n_00000000000000000000000000000003; do
			case "$id" in
				*0003) addr="192.0.2.1"; port="65000";;
				*0002) addr="127.0.0.1"; port="$CLOSED_PORT";;
				*) addr="127.0.0.1"; port="$OPEN_PORT";;
			esac
			echo "config node '$id'"
			echo "	option protocol 'trojan'"
			echo "	option address '$addr'"
			echo "	option port '$port'"
			echo "	option password 'probe-test-password'"
			echo "	option security 'tls'"
		done
	} > "$dir/aetherproxy"
}

make_conf "$T/conf"

# --- driver: scenarios 1-2 in-process (snapshots after every single write) ---
mkdir -p "$T/drv-run"
out="$("$UCODE" "$DRIVER" "$T/drv-run" "$OPEN_PORT" "$CLOSED_PORT" 2>&1)"
rc=$?
printf '%s\n' "$out"
[ "$rc" -eq 0 ] && ok "driver: exit code 0" || bad "driver: exit code 0" "rc=$rc"

# --- scenario 1/2 through the real CLI: probe all nodes, --json equals the final file ---
mkdir -p "$T/run1"
out="$(ap probe nodes --json --confdir "$T/conf" --run-dir "$T/run1" 2>"$T/run1.stderr")"; rc=$?
expect "cli probe all: exit code 0" 0 "$rc"
expect "cli probe all: stderr empty" "" "$(cat "$T/run1.stderr")"
expect "cli probe all: done 3" 3 "$(echo "$out" | jget done)"
expect "cli probe all: total 3" 3 "$(echo "$out" | jget total)"
expect "cli probe all: finished true" true "$(echo "$out" | jget finished)"
expect "cli probe all: pending empty" '<missing>' "$(echo "$out" | jget pending.0)"
[ "$(echo "$out" | jget at)" != '<missing>' ] && ok "cli probe all: at present" || bad "cli probe all: at present"
expect "cli probe all: open node 3/3" 3 "$(echo "$out" | jget nodes.n_00000000000000000000000000000001.ok)"
expect "cli probe all: closed node refused" refused "$(echo "$out" | jget nodes.n_00000000000000000000000000000002.error)"
reason="$(echo "$out" | jget nodes.n_00000000000000000000000000000003.error)"
case "$reason" in timeout|unreachable) ok "cli probe all: TEST-NET node timeout/unreachable";; *) bad "cli probe all: TEST-NET node timeout/unreachable" "got '$reason'";; esac
printf '%s\n' "$out" > "$T/stdout.json"
r="$(jdeq "$T/stdout.json" "$T/run1/probe.json")"
expect "cli probe all: --json output equals the final probe.json" "same" "$r"

# --- scenario 2: a partial run keeps old results of configured nodes, drops vanished ones ---
mkdir -p "$T/run2"
"$UCODE" -e '
	import * as fs from "fs";
	let old = { at: 1234, nodes: {} };
	old.nodes.n_00000000000000000000000000000001 = { ip: "203.0.113.1", ok: 2, fail: 1, min_ms: 10, median_ms: 12, error: null };
	old.nodes.n_00000000000000000000000000000002 = { ip: "198.51.100.2", ok: 0, fail: 3, min_ms: null, median_ms: null, error: "timeout" };
	old.nodes.n_ffffffffffffffffffffffffffffffff = { ip: "203.0.113.9", ok: 1, fail: 2, min_ms: 5, median_ms: 6, error: null };
	if (!fs.writefile(ARGV[0], sprintf("%.J", old) + "\n"))
		exit(1);
' -- "$T/run2/probe.json"
out="$(ap probe nodes n_00000000000000000000000000000001 --json --confdir "$T/conf" --run-dir "$T/run2" 2>"$T/run2.stderr")"; rc=$?
expect "cli probe one: exit code 0" 0 "$rc"
expect "cli probe one: done 1, total 1" "1 1" "$(echo "$out" | jget done) $(echo "$out" | jget total)"
expect "cli probe one: finished true" true "$(echo "$out" | jget finished)"
expect "cli probe one: probed node fresh 3/3" 3 "$(echo "$out" | jget nodes.n_00000000000000000000000000000001.ok)"
"$UCODE" -e '
	import * as fs from "fs";
	function deep(x, y) {
		if (type(x) != type(y))
			return false;
		if (type(x) == "object") {
			if (join("|", sort(keys(x))) != join("|", sort(keys(y))))
				return false;
			for (let k in sort(keys(x)))
				if (!deep(x[k], y[k]))
					return false;
			return true;
		}
		return x === y;
	}
	let f = json(fs.readfile(ARGV[0]));
	let old = { ip: "198.51.100.2", ok: 0, fail: 3, min_ms: null, median_ms: null, error: "timeout" };
	let n = f.nodes;
	print(deep(n.n_00000000000000000000000000000002, old) ? "kept" : "changed", "\n");
	print(n.n_ffffffffffffffffffffffffffffffff == null ? "dropped" : "present", "\n");
	print(f.finished == true ? "finished" : "unfinished", "\n");
' -- "$T/run2/probe.json" > "$T/keep-check.txt"
expect "cli probe one: old result of the unprobed node kept verbatim" "kept" "$(sed -n 1p "$T/keep-check.txt")"
expect "cli probe one: node removed from the configuration dropped" "dropped" "$(sed -n 2p "$T/keep-check.txt")"
expect "cli probe one: final file finished" "finished" "$(sed -n 3p "$T/keep-check.txt")"
printf '%s\n' "$out" > "$T/stdout.json"
r="$(jdeq "$T/stdout.json" "$T/run2/probe.json")"
expect "cli probe one: --json output equals the final probe.json" "same" "$r"

# --- scenario 3: a damaged probe.json counts as empty and does not stop the probe ---
mkdir -p "$T/run3"
printf '{broken json' > "$T/run3/probe.json"
out="$(ap probe nodes n_00000000000000000000000000000001 --json --confdir "$T/conf" --run-dir "$T/run3" 2>"$T/run3.stderr")"; rc=$?
expect "damaged old file: probe exit code 0" 0 "$rc"
expect "damaged old file: probe completed" true "$(echo "$out" | jget finished)"
printf '%s\n' "$out" > "$T/stdout.json"
r="$(jdeq "$T/stdout.json" "$T/run3/probe.json")"
expect "damaged old file: --json output equals the replaced probe.json" "same" "$r"
expect "damaged old file: results reflect the new run" 1 "$(echo "$out" | jget done)"

# --- scenario 4: probe results is read-only, with the documented default ---
mkdir -p "$T/res-run"
out="$(ap probe results --json --run-dir "$T/res-run" 2>"$T/res1.stderr")"; rc=$?
expect "results missing file: exit code 0" 0 "$rc"
expect "results missing file: stderr empty" "" "$(cat "$T/res1.stderr")"
r="$($UCODE -e '
	import * as fs from "fs";
	function deep(x, y) {
		if (type(x) != type(y))
			return false;
		if (type(x) == "object") {
			if (join("|", sort(keys(x))) != join("|", sort(keys(y))))
				return false;
			for (let k in sort(keys(x)))
				if (!deep(x[k], y[k]))
					return false;
			return true;
		}
		if (type(x) == "array") {
			if (length(x) != length(y))
				return false;
			for (let i = 0; i < length(x); i++)
				if (!deep(x[i], y[i]))
					return false;
			return true;
		}
		return x === y;
	}
	let want = { ok: true, at: null, nodes: {}, done: 0, total: 0, finished: true, pending: [] };
	let got = json(fs.stdin.read("all"));
	print(deep(got, want) ? "default" : "other", "\n");
' < <(printf '%s\n' "$out"))"
expect "results missing file: exactly the documented default object" "default" "$r"
[ ! -e "$T/res-run/events.jsonl" ] && ok "results missing file: no events written" || bad "results missing file: no events written" "$(cat "$T/res-run/events.jsonl")"

printf 'not json at all {{{' > "$T/res-run/probe.json"
out="$(ap probe results --json --run-dir "$T/res-run" 2>"$T/res2.stderr")"; rc=$?
expect "results damaged file: exit code 0" 0 "$rc"
echo "$out" | grep -q '"at": null' && ok "results damaged file: default object" || bad "results damaged file: default object" "$out"
[ ! -e "$T/res-run/events.jsonl" ] && ok "results damaged file: no events written" || bad "results damaged file: no events written"

# file exists: the content is returned with ok: true added (docs/07: same shape as the default)
out="$(ap probe results --json --run-dir "$T/run2" 2>"$T/res3.stderr")"; rc=$?
expect "results existing file: exit code 0" 0 "$rc"
printf '%s\n' "$out" > "$T/stdout.json"
python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));d["ok"]=True;json.dump(d,open(sys.argv[2],"w"))' "$T/run2/probe.json" "$T/expected-res.json"
r="$(jdeq "$T/stdout.json" "$T/expected-res.json")"
expect "results existing file: file content plus ok: true" "same" "$r"
[ ! -e "$T/run2/events.jsonl" ] && ok "results existing file: no events written" || bad "results existing file: no events written"

# no --json: human text, exit 0
ap probe results --run-dir "$T/run2" > "$T/res-human.txt" 2>&1; rc=$?
expect "results human output: exit code 0" 0 "$rc"
grep -q 'connected' "$T/res-human.txt" && ok "results human output: human text" || bad "results human output: human text" "$(cat "$T/res-human.txt")"

# extra arguments are rejected
ap probe results n_00000000000000000000000000000001 --json --run-dir "$T/res-run" >/dev/null 2>&1; rc=$?
expect "results with a node ID: usage error, exit 2" 2 "$rc"
out="$(ap probe results n_00000000000000000000000000000001 --json --run-dir "$T/res-run" 2>/dev/null)"
expect "results with a node ID: USAGE code" USAGE "$(echo "$out" | jget code)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
