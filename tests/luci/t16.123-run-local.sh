#!/usr/bin/env bash
# Existing local dependencies/assets only. No SSH, install, worktree creation or commit.
set -u
set -o pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1
export NODE_PATH="${NODE_PATH:-/tmp/t16.23-evidence/node_modules}"
export WWW_ROOT="${WWW_ROOT:-/workspace/openwrt/openwrt-actions/build/rockchip/build_dir/target-aarch64_generic_musl/root-rockchip/www}"
export THEME_ROOT="${THEME_ROOT:-$WWW_ROOT/luci-static/proton2025}"
export THEME_VERSION="${THEME_VERSION:-1.4.5-r1}"
export R6_ROOT="${R6_ROOT:-/tmp/t16122-r6}"
export GIT_OPTIONAL_LOCKS=0
export CI_TOOLS_DIR="${CI_TOOLS_DIR:-/workspace/openwrt/ci-spike/tools}"
# Keep the failed first-round evidence intact.
BASE="${T16123_OUTPUT_DIR:-$ROOT/reports/artifacts/T16.123/round2}"
mkdir -p "$BASE"
fail=0
run() {
 local name="$1"; shift
 "$@" 2>&1 | tee "$BASE/$name.log"
 local rc=${PIPESTATUS[0]}
 printf '%s exit=%s\n' "$name" "$rc" | tee -a "$BASE/results.txt"
 if [ "$rc" -ne 0 ]; then fail=1; fi
}
: > "$BASE/results.txt"
run branch git status --short --branch
run diff-check git diff --check
r6_sha=$(git -C "$R6_ROOT" rev-parse HEAD) || exit 1
if [ "$r6_sha" != 1132c2a96a7109dced4da246ddc8f30518d8f22e ]; then
 printf 'R6_ROOT is not the formal r6 commit\n' >&2; exit 1
fi
r6_dirty=$(git -C "$R6_ROOT" status --porcelain) || exit 1
if [ -n "$r6_dirty" ]; then printf 'R6_ROOT must be clean\n' >&2; exit 1; fi
run syntax-node-gate node --check tests/luci/t16.123-node-mask-gate.js
run syntax-shared-gate node --check tests/luci/t16.122-input-actions-gate.js
run syntax-shell bash -n tests/luci/t16.123-run-local.sh
run luci bash tests/luci/run.sh
for case in visibility layout; do
 # Expected old failures are independent; continue after either one.
 env APP_ROOT="$R6_ROOT" OUTPUT_DIR="$BASE/r6-$case" \
  node --test --test-name-pattern="$case:" tests/luci/t16.122-input-actions-gate.js \
  2>&1 | tee "$BASE/r6-$case.log"
 rc=${PIPESTATUS[0]}
 printf 'r6-%s exit=%s (expected 1; inspect JSON for assertion failure)\n' "$case" "$rc" | tee -a "$BASE/results.txt"
 if [ "$rc" -ne 1 ]; then fail=1; fi
 run "candidate-$case" env APP_ROOT="$ROOT" OUTPUT_DIR="$BASE/candidate-$case" \
  node --test --test-name-pattern="$case:" tests/luci/t16.122-input-actions-gate.js
done
run node-mask env APP_ROOT="$ROOT" OUTPUT_DIR="$BASE/node-mask" \
 node --test tests/luci/t16.123-node-mask-gate.js
run optional-auth node tests/luci/t16.117-optional-auth-preview.js "$WWW_ROOT"
run evidence-proof node - "$BASE" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = process.argv[2];
const read = file => JSON.parse(fs.readFileSync(path.join(root,file),'utf8'));
for (const name of ['visibility','layout']) {
 const old = read(`r6-${name}/${name}.json`);
 const next = read(`candidate-${name}/${name}.json`);
 assert.equal(old.commit,'1132c2a96a7109dced4da246ddc8f30518d8f22e');
 assert.equal(old.dirty,'');
 for (const key of ['version','cssSHA256','controlSHA256','gateSHA256','chromium'])
  assert.equal(old[key],next[key],`baseline/candidate identity: ${key}`);
 assert.equal(old.cases.length,4); assert.equal(next.cases.length,4);
 for (const item of old.cases) {
  assert.equal(item.result,'FAIL');
  assert.match(item.error,name==='visibility' ? /initial empty: clear is painted/ : /clear and eye button hit boxes overlap/);
 }
 for (const item of next.cases) assert.equal(item.result,'PASS');
}
for (const name of ['node-visibility','node-layout','node-lifecycle']) {
 const data=read(`node-mask/${name}.json`);
 assert.equal(data.cases.length,4);
 for (const item of data.cases) { assert.equal(item.result,'PASS'); assert.ok(item.nodeGateSHA256); }
}
console.log('PASS: separate r6 assertion failures, candidate greens and twelve node matrix entries');
NODE
run final-diff-check git diff --check
printf 'Local checks finished; failure flag=%s. Inspect r6 JSON, screenshots and all logs.\n' "$fail"
printf 'No review/commit was performed: review requires a committed report; this handoff forbids commits.\n'
exit "$fail"
