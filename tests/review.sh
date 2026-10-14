#!/usr/bin/env bash
# Pre-review checks for a task branch (docs/tasks/README.md "完成标准").
#
# Usage: bash tests/review.sh [base]      (base defaults to main)
#
# Runs the test suites, then inspects the diff between <base> and HEAD for the
# violations reviewers keep finding. Prints PASS/WARN/FAIL lines and exits 1 if
# anything FAILed. WARN items are not errors but must be explained in the report.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."

BASE="${1:-main}"
fails=0 warns=0
pass() { printf 'PASS  %s\n' "$1"; }
warn() { printf 'WARN  %s\n' "$1"; warns=$((warns + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

if ! git rev-parse --verify -q "$BASE" >/dev/null; then
	echo "review: base '$BASE' not found" >&2
	exit 2
fi

changed=$(git diff --name-only "$BASE"...HEAD)

echo "== branch $(git rev-parse --abbrev-ref HEAD) vs $BASE: $(git rev-list --count "$BASE"..HEAD) commit(s), $(printf '%s\n' "$changed" | grep -c .) file(s)"

# --- 1. test suites -----------------------------------------------------------
if [ ! -x tests/host/prefix/bin/ucode ]; then
	bash tests/host/bootstrap.sh >/dev/null || { fail "bootstrap.sh failed"; exit 1; }
fi

out=$(tests/host/ucode tests/run.uc 2>&1); rc=$?
summary=$(printf '%s\n' "$out" | tail -1)
if [ $rc -eq 0 ]; then pass "tests/run.uc: $summary"; else fail "tests/run.uc: $summary"; printf '%s\n' "$out" | grep -E '^FAIL' | sed 's/^/      /'; fi

out=$(bash tests/cli/run.sh 2>&1); rc=$?
summary=$(printf '%s\n' "$out" | tail -1)
if [ $rc -eq 0 ]; then pass "tests/cli/run.sh: $summary"; else fail "tests/cli/run.sh: $summary"; printf '%s\n' "$out" | grep -E '^FAIL' | sed 's/^/      /'; fi

# Real-Xray check only when a cached binary exists; never downloads from here.
xray_cache="${CI_TOOLS_DIR:-}"
if [ -n "$xray_cache" ] && ls "$xray_cache"/xray-*/xray >/dev/null 2>&1; then
	out=$(CI_TOOLS_DIR="$xray_cache" bash tests/ci/xray.sh 2>&1); rc=$?
	summary=$(printf '%s\n' "$out" | tail -1)
	if [ $rc -eq 0 ]; then pass "tests/ci/xray.sh: $summary"; else fail "tests/ci/xray.sh: $summary"; printf '%s\n' "$out" | grep -E '^FAIL' | sed 's/^/      /'; fi
else
	warn "xray -test skipped (set CI_TOOLS_DIR to a directory holding xray-<ver>/xray to run it)"
fi

# --- 2. every changed .uc compiles --------------------------------------------
uc_bad=0
for f in $(printf '%s\n' "$changed" | grep -E '\.uc$'); do
	[ -f "$f" ] || continue
	case "$f" in
	aether-proxy/src/lib/*)
		mod="aetherproxy.$(printf '%s' "${f#aether-proxy/src/lib/}" | sed 's/\.uc$//; s#/#.#g')"
		err=$(tests/host/ucode -e "import * as m from '$mod';" 2>&1) || { fail "$f does not load as $mod"; printf '%s\n' "$err" | head -5 | sed 's/^/      /'; uc_bad=1; }
		;;
	*)
		err=$(tests/host/ucode -c -o /dev/null "$f" 2>&1) || { fail "$f does not compile"; printf '%s\n' "$err" | head -5 | sed 's/^/      /'; uc_bad=1; }
		;;
	esac
done
[ $uc_bad -eq 0 ] && pass "changed .uc files compile/load"

# --- 3. forbidden patterns in added product code ------------------------------
added=$(git diff -U0 "$BASE"...HEAD -- aether-proxy luci-app-aether-proxy | grep -E '^\+[^+]' || true)

if printf '%s\n' "$added" | grep -nE '2>/dev/null|\|\| *true' >/dev/null; then
	fail "added code swallows errors (2>/dev/null or || true; README rule 2)"
	printf '%s\n' "$added" | grep -E '2>/dev/null|\|\| *true' | head -5 | sed 's/^/      /'
else
	pass "no swallowed errors in added code"
fi

hits=$(git diff -U0 "$BASE"...HEAD -- aether-proxy/src/lib ':(exclude)aether-proxy/src/lib/sys.uc' | grep -E '^\+[^+]' | grep -E '\b(system|popen)\(' || true)
if [ -n "$hits" ]; then
	fail "system()/popen() outside sys.uc (docs/12 rule 2)"
	printf '%s\n' "$hits" | head -5 | sed 's/^/      /'
else
	pass "no system()/popen() outside sys.uc"
fi

if printf '%s\n' "$added" | grep -E '^\+.*\brequire\(' >/dev/null; then
	warn "added code uses require() (cannot load modules with exports; docs/12 syntax limit 3)"
fi

if printf '%s\n' "$added" | grep -E '^\+.*\.join\(' >/dev/null; then
	fail "added code calls .join() (ucode arrays have no .join; use join(sep, arr))"
fi

# --- 4. scope of the change ---------------------------------------------------
if printf '%s\n' "$changed" | grep -q '^docs/'; then
	warn "docs/ changed (only spike cards may change docs; explain in the report)"
	printf '%s\n' "$changed" | grep '^docs/' | sed 's/^/      /'
fi
for f in tests/run.uc .github/workflows/test.yml tests/host/bootstrap.sh; do
	printf '%s\n' "$changed" | grep -qx "$f" && warn "$f changed (shared infrastructure; explain in the report)"
done
mod_expected=$(git diff --name-only --diff-filter=M "$BASE"...HEAD -- 'tests/fixtures/*/expected/*' || true)
if [ -n "$mod_expected" ]; then
	warn "existing expected files modified (explain each in the report)"
	printf '%s\n' "$mod_expected" | sed 's/^/      /'
fi

# --- 5. commits and report ----------------------------------------------------
if git log --format=%B "$BASE"..HEAD | grep -qiE 'co-authored-by|generated with'; then
	fail "commit messages contain AI attribution trailers"
else
	pass "no attribution trailers in commits"
fi
bad_subj=$(git log --format=%s "$BASE"..HEAD | grep -vE '^[^[:alnum:][:space:]]+ [a-z]+(\([a-z0-9._-]+\))?: ' || true)
[ -n "$bad_subj" ] && { warn "commit subjects not in emoji format"; printf '%s\n' "$bad_subj" | sed 's/^/      /'; }

reports=$(printf '%s\n' "$changed" | grep -E '^reports/[^/]+\.md$' || true)
if [ -z "$reports" ]; then
	fail "no reports/<card>.md in the branch (docs/tasks/README.md)"
else
	pass "report present: $reports"
fi

if [ -n "$(git status --porcelain)" ]; then
	warn "working tree not clean (uncommitted changes are not reviewed)"
fi
main_wt=$(git worktree list --porcelain | sed -n '1s/^worktree //p')
if [ "$main_wt" != "$(pwd)" ] && [ -n "$(git -C "$main_wt" status --porcelain)" ]; then
	fail "main checkout $main_wt has uncommitted changes (task work must stay in its own worktree)"
	git -C "$main_wt" status --porcelain | head -5 | sed 's/^/      /'
fi

echo "== $fails FAIL, $warns WARN"
[ $fails -eq 0 ]
