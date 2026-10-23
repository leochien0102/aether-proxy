#!/usr/bin/env bash
# Sourced by run.sh: docs/10 DNS jobs use their own kind lock, not update/probe/sub locks.
# Reuse the existing job substitute without changing the shared tests/stubs directory.

start_dns() {
	ap job start dns test-direct --confdir "$T/conf" --run-dir "$RUN" --sys-root "$R" --bin-dir "$T/bin"
}

cp "$STUB" "$T/bin/aether-proxy"
chmod +x "$T/bin/aether-proxy"
make_root "$T/dns-result"
export JOB_STUB_JSON='{"ok":true,"results":[{"upstream":"tls://127.0.0.1#853","unblocked":{"domain":"www.microsoft.com","ok":0,"total":3,"latency_ms":null},"blocked":{"domain":"www.google.com","ok":0,"total":3,"latency_ms":null},"unsupported":true}]}'
out=$(start_dns); rc=$?
unset JOB_STUB_JSON
expect "T9.28 dns_test job start succeeds" 0 "$rc"
id=$(get_json "$out" job)
[[ "$id" =~ ^j_[0-9]+_[0-9]+$ ]] && ok "T9.28 dns_test returns a job ID" || bad "T9.28 dns_test returns a job ID" "$out"
if result=$(wait_terminal "$id" ok); then
	ok "T9.28 dns_test job status reaches ok with result"
	expect "T9.28 dns_test stores its own kind" dns_test "$(get_json "$result" kind)"
	expect "T9.28 dns_test stores the displayed command" 'dns test-direct' "$(get_json "$result" cmd)"
	expect "T9.28 dns_test preserves parsed child result" true "$(get_json "$result" result.results.0.unsupported)"
	grep -Fxq 'ARG=dns' "$T/stub.log" && grep -Fxq 'ARG=test-direct' "$T/stub.log" \
		&& grep -Fxq "ARG=$T/conf" "$T/stub.log" && grep -Fxq "ARG=$RUN" "$T/stub.log" \
		&& grep -Fxq "ARG=$R" "$T/stub.log" && grep -Fxq "ARG=$T/bin" "$T/stub.log" \
		&& grep -Fxq 'ARG=--json' "$T/stub.log" \
		&& ok "T9.28 dns_test forwards context options and --json" \
		|| bad "T9.28 dns_test forwards context options and --json"
else
	bad "T9.28 dns_test job status reaches ok with result" "$result"
fi

# Keep another DNS worker alive so both the start-time BUSY check and cross-kind
# concurrency are exercised, not merely the presence of a lock filename.
make_root "$T/dns-concurrent"
export JOB_STUB_MODE=sleep JOB_STUB_SLEEP=3
out=$(start_dns); rc=$?
dns_id=$(get_json "$out" job)
expect "T9.28 slow dns_test starts" 0 "$rc"
for _ in {1..100}; do
	[ -e "$R/var/lock/aether-proxy-job-dns_test.lock" ] && break
	sleep 0.02
done
busy=$(start_dns); rc=$?
expect "T9.28 same-kind dns_test returns BUSY" 3 "$rc"
expect "T9.28 dns_test BUSY names the running job" "$dns_id" "$(get_json "$busy" job)"
if flock -n "$R/var/lock/aether-proxy-job-dns_test.lock" -c ':'; then
	bad "T9.28 dns_test worker holds its own kind lock"
else
	ok "T9.28 dns_test worker holds its own kind lock"
fi
concurrent_ids=("$dns_id")
for family in probe sub update; do
	case "$family" in
	probe) out=$(start_probe); rc=$? ;;
	sub) out=$(start_sub); rc=$? ;;
	update) out=$(ap job start update check --run-dir "$RUN" --sys-root "$R" --bin-dir "$T/bin"); rc=$? ;;
	esac
	expect "T9.28 $family starts alongside dns_test" 0 "$rc"
	concurrent_ids+=("$(get_json "$out" job)")
done
for id in "${concurrent_ids[@]}"; do
	if wait_terminal "$id" ok >/dev/null; then
		ok "T9.28 independent DNS/probe/sub/update worker finishes ok"
	else
		bad "T9.28 independent DNS/probe/sub/update worker finishes ok" "$id"
	fi
done
unset JOB_STUB_MODE JOB_STUB_SLEEP
if flock -n "$R/var/lock/aether-proxy-job-dns_test.lock" -c ':'; then
	ok "T9.28 dns_test releases its kind lock on completion"
else
	bad "T9.28 dns_test releases its kind lock on completion"
fi

# Prehold only the DNS lock: no running job file exists, so the worker's lock
# acquisition (not the start-time scan) must reject this job before running a child.
make_root "$T/dns-preheld"
exec {dns_lock_fd}>"$R/var/lock/aether-proxy-job-dns_test.lock"
flock -x "$dns_lock_fd"
out=$(start_dns); rc=$?
id=$(get_json "$out" job)
expect "T9.28 dns_test with preheld lock still returns a job ID" 0 "$rc"
if result=$(wait_terminal "$id" failed); then
	expect "T9.28 preheld DNS lock makes worker BUSY" BUSY "$(get_json "$result" error)"
	expect "T9.28 preheld DNS lock records exit 3" 3 "$(get_json "$result" exit)"
	[ ! -s "$T/stub.log" ] && ok "T9.28 preheld DNS lock prevents child execution" \
		|| bad "T9.28 preheld DNS lock prevents child execution"
else
	bad "T9.28 preheld DNS lock makes worker BUSY" "$result"
fi
flock -u "$dns_lock_fd"
exec {dns_lock_fd}>&-

out=$(ap job start dns sync-wan --run-dir "$RUN" --sys-root "$R"); rc=$?
expect "T9.28 dns sync-wan remains rejected as a job" 2 "$rc"
expect "T9.28 unsupported DNS job reports USAGE" USAGE "$(get_json "$out" code)"

# The second wrapper always runs the real entry point, including the DNS child.
# A loopback-only TLS upstream is unsupported without any network access/delay.
make_root "$T/dns-real"
mkdir -p "$T/real-bin"
printf '#!/bin/sh\nexec "$JOB_UCODE" -S "$JOB_ENTRY" -- "$@"\n' > "$T/real-bin/aether-proxy"
chmod +x "$T/real-bin/aether-proxy"
printf "config main 'main'\n\toption enabled '0'\nconfig dns 'dns'\n\toption direct_dns_enabled '0'\n\tlist direct_dns 'tls://127.0.0.1#853'\n" > "$T/conf/aetherproxy"
job_env "$UCODE" -S "$ENTRY" -- dns test-direct --json --confdir "$T/conf" \
	--run-dir "$RUN" --sys-root "$R" > "$T/dns-direct.json" 2> "$T/dns-direct.err"
rc=$?
expect "T9.28 real dns test-direct unsupported configuration succeeds" 0 "$rc"
[ ! -s "$T/dns-direct.err" ] && ok "T9.28 real dns test-direct has empty stderr" \
	|| bad "T9.28 real dns test-direct has empty stderr" "$(<"$T/dns-direct.err")"
out=$(ap job start dns test-direct --confdir "$T/conf" --run-dir "$RUN" \
	--sys-root "$R" --bin-dir "$T/real-bin"); rc=$?
expect "T9.28 real dns_test job start succeeds" 0 "$rc"
id=$(get_json "$out" job)
if result=$(wait_terminal "$id" ok); then
	ok "T9.28 real dns_test job status reaches ok"
	if python3 "$ROOT/tests/job/check-dns-result.py" "$T/dns-direct.json" "$RUN/jobs/$id.json"; then
		ok "T9.28 real dns_test preserves unsupported loopback result exactly"
	else
		bad "T9.28 real dns_test preserves unsupported loopback result exactly"
	fi
else
	bad "T9.28 real dns_test job status reaches ok" "$result"
fi

# Kind recognition permits context flags, but an extra positional argument must
# still be rejected by the real CLI and recorded as a failed job, never as ok.
out=$(ap dns test-direct extra --json --confdir "$T/conf" --run-dir "$RUN" --sys-root "$R"); rc=$?
expect "T9.28 real DNS CLI rejects extra positional argument with exit 2" 2 "$rc"
expect "T9.28 real DNS CLI extra positional argument is USAGE" USAGE "$(get_json "$out" code)"
out=$(ap job start dns test-direct extra --confdir "$T/conf" --run-dir "$RUN" \
	--sys-root "$R" --bin-dir "$T/real-bin"); rc=$?
expect "T9.28 invalid DNS command starts a validation worker" 0 "$rc"
id=$(get_json "$out" job)
if result=$(wait_terminal "$id" failed); then
	ok "T9.28 invalid DNS job reaches failed instead of ok"
	expect "T9.28 invalid DNS job preserves USAGE error" USAGE "$(get_json "$result" error)"
	expect "T9.28 invalid DNS job preserves exit 2" 2 "$(get_json "$result" exit)"
	expect "T9.28 invalid DNS job preserves failed CLI result" false "$(get_json "$result" result.ok)"
	expect "T9.28 invalid DNS job result contains USAGE" USAGE "$(get_json "$result" result.code)"
else
	bad "T9.28 invalid DNS job reaches failed instead of ok" "$result"
fi
