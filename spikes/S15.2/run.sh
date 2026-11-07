#!/usr/bin/env bash
# Reproduce S15.2 loopback evidence and kill three intentionally broken designs.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
out=spikes/S15.2/evidence
mkdir -p "$out"
python3 spikes/S15.2/probe.py --output "$out/normal.jsonl" > "$out/normal.log" 2>&1
printf '%s\n' '== normal A/B experiment'
while IFS= read -r line; do printf '%s\n' "$line"; done < "$out/normal.log"
for mutation in tproxy-only closed-handoff client-leak; do
    case "$mutation" in
        tproxy-only) expected='A-P5 gate cannot pass before delayed DNS tunnel' ;;
        closed-handoff) expected='A-P2 explicit bootstrap independent of closed handoff' ;;
        client-leak) expected='A-P2 ordinary gfw never reaches bootstrap or system' ;;
    esac
    if python3 spikes/S15.2/probe.py --mutation "$mutation" \
        --output "$out/$mutation.jsonl" > "$out/$mutation.log" 2>&1; then
        printf 'FAIL mutation survived: %s\n' "$mutation" >&2
        exit 1
    fi
    if ! grep -Fxq "AssertionError: $expected" "$out/$mutation.log"; then
        printf 'FAIL wrong mutation failure: %s (see %s)\n' "$mutation" "$out/$mutation.log" >&2
        exit 1
    fi
    printf 'PASS negative %s rejected by %s\n' "$mutation" "$expected"
done
python3 spikes/S15.2/probe.py --output "$out/restored.jsonl" > "$out/restored.log" 2>&1
printf 'PASS restored normal experiment after all three mutations\n'
