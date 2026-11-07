#!/usr/bin/env bash
# S15.3: build only the explicitly allowed source snapshot; never write its source repository.
set -euo pipefail
cd "$(dirname "$0")/../.."
BASE="$PWD/spikes/S15.3"
SOURCE=/workspace/openwrt/aether-dns
COMMIT=a3d42a278ce84ba5ed54988a9d30a695b7ec97b5
FALLBACK=/workspace/openwrt/ci-spike/tools/chinadns-ng-2025.08.09/chinadns-ng
HASH=842ea4e9816efd91d39bc76ead5c4a42e79011757e37c521b4270b675cfcb30c
mkdir -p "$BASE/evidence"
blocked() {
    for engine in aether-dns chinadns-ng; do
        for n in {1..10}; do printf 'BLOCKED %s E%s: %s\n' "$engine" "$n" "$*"; done
    done
    exit 2
}
for tool in git cargo rustc python3 openssl sha256sum file; do
    command -v "$tool" >/dev/null || blocked "missing tool: $tool"
done
[[ -x "$FALLBACK" ]] || blocked 'missing pinned chinadns-ng binary (no auto-download)'
actual=$(sha256sum "$FALLBACK")
[[ "${actual%% *}" == "$HASH" ]] || blocked 'fallback SHA256 differs from package baseline'
git -C "$SOURCE" cat-file -e "$COMMIT^{commit}" || blocked 'aether-dns commit unavailable'
git -C "$SOURCE" merge-base --is-ancestor 325b614 "$COMMIT" || blocked 'snapshot lacks M4-01 merge'
if [[ ! -d "$BASE/.build/source" ]]; then
    mkdir -p "$BASE/.build/source"
    git -C "$SOURCE" archive "$COMMIT" | tar -x -C "$BASE/.build/source"
fi
# Rebuild offline, with Cargo.lock, on every invocation. No third-party code is committed.
if ! (cd "$BASE/.build/source" && cargo build --release --locked --offline) >"$BASE/evidence/build.log" 2>&1; then
    blocked 'offline snapshot build failed; see evidence/build.log'
fi
AETHER="$BASE/.build/source/target/release/aether-dns"
{
    printf 'aether-dns source: %s commit %s\n' "$SOURCE" "$COMMIT"
    printf 'M4-01 ancestor: 325b614\n'
    printf 'fallback source: https://github.com/zfl9/chinadns-ng/releases/download/2025.08.09/chinadns-ng+wolfssl@x86_64-linux-musl@x86_64@fast+lto\n'
    uname -m
    rustc -V
    cargo -V
    file "$AETHER" "$FALLBACK"
    sha256sum "$AETHER" "$FALLBACK"
    wc -c "$AETHER" "$FALLBACK"
    "$AETHER" -V
    "$FALLBACK" -V
} > "$BASE/evidence/provenance.txt"
python3 "$BASE/suite.py" "$AETHER" "$FALLBACK"
