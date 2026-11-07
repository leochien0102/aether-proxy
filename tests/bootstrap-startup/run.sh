#!/usr/bin/env bash
# T15.6 / 8e4d6a2: real bootstrap+B1 and actual daemon, then isolated module gate.
set -euo pipefail
cd "$(dirname "$0")/../.."
BASE="$PWD/tests/bootstrap-startup"
SOURCE=/workspace/openwrt/aether-dns
COMMIT=a3d42a278ce84ba5ed54988a9d30a695b7ec97b5
FALLBACK=/workspace/openwrt/ci-spike/tools/chinadns-ng-2025.08.09/chinadns-ng
mkdir -p "$BASE/.logs" "$BASE/.build/source"
for tool in git cargo rustc python3 sha256sum; do
    if ! command -v "$tool" >/dev/null; then echo "BLOCKED missing $tool"; exit 2; fi
done
if [[ ! -x "$FALLBACK" ]]; then echo 'BLOCKED missing pinned fallback engine'; exit 2; fi
actual=$(sha256sum "$FALLBACK")
if [[ "${actual%% *}" != 842ea4e9816efd91d39bc76ead5c4a42e79011757e37c521b4270b675cfcb30c ]]; then
    echo 'BLOCKED fallback hash mismatch'; exit 2
fi
# Only archive reads the source repository; compilation/output stay in this worktree.
git -C "$SOURCE" archive "$COMMIT" | tar -x -C "$BASE/.build/source"
(cd "$BASE/.build/source" && cargo build --release --locked --offline) > "$BASE/.logs/engine-build.log" 2>&1
{
    printf 'source=%s commit=%s\n' "$SOURCE" "$COMMIT"
    rustc -V
    cargo -V
    sha256sum "$BASE/.build/source/target/release/aether-dns" "$FALLBACK"
} > "$BASE/.logs/provenance.log"
python3 "$BASE/run.py"
python3 tests/xray-ready/minimal.py
if [[ "${1:-}" = --mutations ]]; then python3 "$BASE/mutations.py"; fi
