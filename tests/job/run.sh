#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UCODE="$ROOT/tests/host/ucode"
ENTRY="$ROOT/aether-proxy/src/aether-proxy"
JGET="$ROOT/tests/cli/jget.uc"
STUB="$ROOT/tests/stubs/job-bin/aether-proxy"
T="$(mktemp -d "$ROOT/tests/job/tmp.XXXXXX")"
R=''
RUN=''
pass=0
fail=0

cleanup() {
	if [ -n "$T" ] && [ -d "$T" ]; then
		if [ "${KEEP_TMP:-0}" = 1 ]; then echo "kept job-test temp: $T"; else rm -rf "$T"; fi
	fi
}
trap cleanup EXIT INT TERM

ok() { pass=$((pass + 1)); echo "PASS  $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1${2:+: $2}"; }
expect() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected '$2', got '$3'"; }
get_json() { printf '%s\n' "$1" | "$UCODE" "$JGET" -- "$2"; }

job_env() {
	env JOB_UCODE="$UCODE" JOB_ENTRY="$ENTRY" JOB_STUB_LOG="$T/stub.log" \
		JOB_STUB_MODE="${JOB_STUB_MODE:-json}" JOB_STUB_EXIT="${JOB_STUB_EXIT:-0}" \
		JOB_STUB_JSON="${JOB_STUB_JSON:-}" JOB_STUB_OUTPUT="${JOB_STUB_OUTPUT:-not-json output}" \
		JOB_STUB_SLEEP="${JOB_STUB_SLEEP:-1}" "$@"
}

ap() { job_env "$UCODE" -S "$ENTRY" -- "$@"; }

make_root() {
	R="$1"
	RUN="$R/var/run/aether-proxy"
	mkdir -p "$R/var/lock" "$RUN" "$RUN/jobs" "$R/etc/config" "$T/conf"
	: > "$T/stub.log"
}

start_probe() {
	ap job start probe nodes --confdir "$T/conf" --run-dir "$RUN" --sys-root "$R" --bin-dir "$T/bin"
}

start_sub() {
	ap job start sub update --confdir "$T/conf" --run-dir "$RUN" --sys-root "$R" --bin-dir "$T/bin"
}

status_job() {
	ap job status "$1" --json --run-dir "$RUN" --sys-root "$R"
}

wait_terminal() {
	local id="$1" want="${2:-}" output state
	for _ in {1..150}; do
		output=$(status_job "$id")
		state=$(get_json "$output" state)
		if [ "$state" = 'ok' ] || [ "$state" = 'failed' ]; then
			[ -z "$want" ] || [ "$state" = "$want" ] || { echo "$output"; return 1; }
			printf '%s\n' "$output"
			return 0
		fi
		sleep 0.05
	done
	return 1
}

mkdir -p "$T/bin"
cp "$STUB" "$T/bin/aether-proxy"
chmod +x "$T/bin/aether-proxy"

# Start is prompt, returns an ID in the documented format, and stores parsed JSON output.
make_root "$T/root1"
export JOB_STUB_JSON='{"ok":true,"nodes":{"n_demo":{"ok":3,"fail":0}}}'
start_ns=$(date +%s%N)
out=$(start_probe); rc=$?
end_ns=$(date +%s%N)
unset JOB_STUB_JSON
expect "job start succeeds" 0 "$rc"
id=$(get_json "$out" job)
[[ "$id" =~ ^j_[0-9]+_[0-9]+$ ]] && ok "job ID format" || bad "job ID format" "$id"
elapsed_ns=$((end_ns - start_ns))
[ "$elapsed_ns" -lt 1000000000 ] && ok "job start returns in under one second" || bad "job start returns in under one second" "${elapsed_ns}ns"
if result=$(wait_terminal "$id" ok); then
	ok "probe job reaches ok"
	expect "job result JSON is parsed" 3 "$(get_json "$result" result.nodes.n_demo.ok)"
	expect "successful child exit is recorded" 0 "$(get_json "$result" exit)"
else
	bad "probe job reaches ok"
fi

# A failing child can return its own event code in JSON.
export JOB_STUB_JSON='{"ok":false,"code":"SUB_FETCH_FAILED"}' JOB_STUB_EXIT=1
out=$(start_sub); rc=$?
unset JOB_STUB_JSON JOB_STUB_EXIT
id=$(get_json "$out" job)
expect "failing subscription job starts" 0 "$rc"
if result=$(wait_terminal "$id" failed); then
	expect "child event code is preserved" SUB_FETCH_FAILED "$(get_json "$result" error)"
	expect "failed child JSON remains available" false "$(get_json "$result" result.ok)"
else
	bad "subscription job reaches failed"
fi

# sub update reports per subscription (no top-level code): the job surfaces the first failing one.
export JOB_STUB_JSON='{"ok":false,"subs":{"s_00000001":{"ok":true,"code":null},"s_00000002":{"ok":false,"code":"SUB_NO_VALID_NODES"}}}' JOB_STUB_EXIT=1
out=$(start_sub); rc=$?
unset JOB_STUB_JSON JOB_STUB_EXIT
id=$(get_json "$out" job)
if result=$(wait_terminal "$id" failed); then
	expect "per-subscription failure code becomes the job error" SUB_NO_VALID_NODES "$(get_json "$result" error)"
else
	bad "per-subscription failure job reaches failed"
fi

# Invalid stdout is not silently accepted as a successful result.
export JOB_STUB_MODE=invalid JOB_STUB_OUTPUT='stub output is not JSON'
out=$(start_probe); rc=$?
unset JOB_STUB_MODE JOB_STUB_OUTPUT
id=$(get_json "$out" job)
expect "invalid-output job starts" 0 "$rc"
if result=$(wait_terminal "$id" failed); then
	expect "invalid JSON is CMD_FAILED" CMD_FAILED "$(get_json "$result" error)"
	expect "invalid JSON detail preserves raw stdout" 'stub output is not JSON' "$(get_json "$result" detail)"
	expect "invalid JSON result is null" '<missing>' "$(get_json "$result" result)"
else
	bad "invalid-output job reaches failed"
fi

# Same-kind jobs are BUSY; a different kind can run alongside one.
export JOB_STUB_MODE=sleep JOB_STUB_SLEEP=2
start_ns=$(date +%s%N)
out=$(start_probe); rc=$?
probe_id=$(get_json "$out" job)
expect "slow probe job starts" 0 "$rc"
for _ in {1..100}; do
	probe_status=$(status_job "$probe_id")
	probe_pid=$(get_json "$probe_status" pid)
	[ "$probe_pid" != '<missing>' ] && break
	sleep 0.02
done
busy=$(start_probe); busy_rc=$?
expect "same-kind job returns BUSY" 3 "$busy_rc"
expect "BUSY names the running job" "$probe_id" "$(get_json "$busy" job)"
out=$(start_sub); rc=$?
sub_id=$(get_json "$out" job)
expect "different-kind job starts concurrently" 0 "$rc"
if wait_terminal "$probe_id" ok >/dev/null && wait_terminal "$sub_id" ok >/dev/null; then
	ok "different job kinds finish concurrently"
else
	bad "different job kinds finish concurrently"
fi
end_ns=$(date +%s%N)
elapsed_ns=$((end_ns - start_ns))
[ "$elapsed_ns" -lt 3500000000 ] && ok "different kinds overlap instead of serializing" || bad "different kinds overlap instead of serializing" "${elapsed_ns}ns"
unset JOB_STUB_MODE JOB_STUB_SLEEP

# Killing a live worker is detected on the next status request and emits JOB_LOST.
export JOB_STUB_MODE=sleep JOB_STUB_SLEEP=3
out=$(start_probe); rc=$?
id=$(get_json "$out" job)
expect "kill-test job starts" 0 "$rc"
for _ in {1..100}; do
	status=$(status_job "$id")
	pid=$(get_json "$status" pid)
	[ "$pid" != '<missing>' ] && break
	sleep 0.02
done
if [[ "$pid" =~ ^[0-9]+$ ]] && kill -KILL "$pid"; then
	ok "worker can be terminated for lost-job test"
else
	bad "worker can be terminated for lost-job test" "pid=$pid"
fi
lost=$(status_job "$id"); rc=$?
expect "killed worker status exits successfully" 0 "$rc"
expect "killed worker becomes JOB_LOST" JOB_LOST "$(get_json "$lost" error)"
grep -q '"code": "JOB_LOST"' "$RUN/events.jsonl" \
	&& ok "JOB_LOST event is recorded" || bad "JOB_LOST event is recorded"
sleep 3
unset JOB_STUB_MODE JOB_STUB_SLEEP

# Unsupported task kinds, malformed IDs, and missing IDs use the specified exit codes.
out=$(ap job start daemon); rc=$?
expect "daemon is rejected as a job" 2 "$rc"
expect "daemon rejection is USAGE" USAGE "$(get_json "$out" code)"
out=$(ap job start check); rc=$?
expect "check is rejected as a job" 2 "$rc"
expect "check rejection is USAGE" USAGE "$(get_json "$out" code)"
out=$(ap job status abc --json --run-dir "$RUN" --sys-root "$R"); rc=$?
expect "malformed status ID exits 2" 2 "$rc"
expect "malformed status ID is USAGE" USAGE "$(get_json "$out" code)"
out=$(ap job status j_1_1 --json --run-dir "$RUN" --sys-root "$R"); rc=$?
expect "missing status ID exits 2" 2 "$rc"
expect "missing status ID is JOB_NOT_FOUND" JOB_NOT_FOUND "$(get_json "$out" code)"

# The worker outlives the shell that issued job start.
make_root "$T/root2"
export JOB_STUB_MODE=sleep JOB_STUB_SLEEP=1 JOB_STUB_JSON='{"ok":true,"detached":true}'
caller_output="$T/caller.out"
caller_error="$T/caller.err"
sh -c 'exec env JOB_UCODE="$1" JOB_ENTRY="$2" JOB_STUB_LOG="$3" JOB_STUB_MODE="$4" JOB_STUB_SLEEP="$5" JOB_STUB_JSON="$6" "$1" -S "$2" -- job start probe nodes --run-dir "$7" --sys-root "$8" --bin-dir "$9"' \
	sh "$UCODE" "$ENTRY" "$T/stub.log" "$JOB_STUB_MODE" "$JOB_STUB_SLEEP" "$JOB_STUB_JSON" "$RUN" "$R" "$T/bin" \
	>"$caller_output" 2>"$caller_error"; rc=$?
expect "short-lived caller shell exits successfully" 0 "$rc"
id=$(get_json "$(cat "$caller_output")" job)
if result=$(wait_terminal "$id" ok); then
	expect "job finishes after caller exits" true "$(get_json "$result" result.detached)"
else
	bad "job finishes after caller exits"
fi
unset JOB_STUB_MODE JOB_STUB_SLEEP JOB_STUB_JSON

# Startup removes only jobs finished over an hour ago.
make_root "$T/root3"
old_id='j_100_101'
recent_id='j_102_103'
old_finished=$(($(date +%s) - 7200))
recent_finished=$(($(date +%s) - 600))
cat > "$RUN/jobs/$old_id.json" <<EOF
{"id":"$old_id","kind":"probe_nodes","cmd":"probe nodes","argv":["probe","nodes"],"state":"ok","pid":101,"started":1,"finished":$old_finished,"exit":0,"result":{"ok":true},"error":null,"detail":null}
EOF
cat > "$RUN/jobs/$recent_id.json" <<EOF
{"id":"$recent_id","kind":"sub_update","cmd":"sub update","argv":["sub","update"],"state":"ok","pid":103,"started":1,"finished":$recent_finished,"exit":0,"result":{"ok":true},"error":null,"detail":null}
EOF
out=$(start_probe); rc=$?
expect "cleanup test starts a new job" 0 "$rc"
id=$(get_json "$out" job)
[ ! -e "$RUN/jobs/$old_id.json" ] && ok "job older than one hour is removed" || bad "job older than one hour is removed"
[ -e "$RUN/jobs/$recent_id.json" ] && ok "recent finished job is retained" || bad "recent finished job is retained"
if wait_terminal "$id" ok >/dev/null; then ok "cleanup-test job completes"; else bad "cleanup-test job completes"; fi

# A corrupt job file (damage from outside) is logged and removed; it must not block new jobs
# or crash status.
make_root "$T/root-corrupt"
printf '{broken' > "$RUN/jobs/j_200_201.json"
out=$(ap job status j_200_201 --json --run-dir "$RUN" --sys-root "$R" 2>/dev/null); rc=$?
[ "$rc" -ne 0 ] && [ "$rc" -lt 128 ] && ok "status of a corrupt job file fails cleanly (rc=$rc)" || bad "status of a corrupt job file fails cleanly" "rc=$rc"
out=$(start_probe); rc=$?
expect "a corrupt job file does not block job start" 0 "$rc"
[ ! -e "$RUN/jobs/j_200_201.json" ] && ok "the corrupt job file is removed" || bad "the corrupt job file is removed"
id=$(get_json "$out" job)
if wait_terminal "$id" ok >/dev/null; then ok "job after corrupt-file cleanup completes"; else bad "job after corrupt-file cleanup completes"; fi

# Test-only options are saved in argv and passed to the child together with --json.
make_root "$T/root4"
ALT_RUN="$R/var/run/custom-jobs"
mkdir -p "$ALT_RUN"
export JOB_STUB_JSON='{"ok":true,"args":true}'
out=$(ap job start sub update --confdir "$T/conf" --run-dir "$ALT_RUN" --sys-root "$R" --bin-dir "$T/bin"); rc=$?
unset JOB_STUB_JSON
expect "option-forwarding job starts" 0 "$rc"
id=$(get_json "$out" job)
if result=$(ap job status "$id" --json --run-dir "$ALT_RUN" --sys-root "$R"); then
	# The first status may still be running; use the common poller with the alternate run-dir.
	alt_result="$result"
	for _ in {1..150}; do
		alt_result=$(ap job status "$id" --json --run-dir "$ALT_RUN" --sys-root "$R")
		state=$(get_json "$alt_result" state)
		[ "$state" = 'ok' ] || [ "$state" = 'failed' ] && break
		sleep 0.05
	done
	if [ "$(get_json "$alt_result" state)" = 'ok' ]; then ok "option-forwarding job completes"; else bad "option-forwarding job completes"; fi
else
	bad "option-forwarding status can be read"
fi
grep -Fq "ARG=--confdir" "$T/stub.log" \
	&& grep -Fq "ARG=$T/conf" "$T/stub.log" \
	&& grep -Fq "ARG=--run-dir" "$T/stub.log" \
	&& grep -Fq "ARG=$ALT_RUN" "$T/stub.log" \
	&& grep -Fq 'ARG=--json' "$T/stub.log" \
	&& ok "test options and --json reach the child unchanged" || bad "test options and --json reach the child unchanged"

echo "job: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
