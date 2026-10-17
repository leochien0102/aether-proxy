#!/usr/bin/env bash
# Dashboard traffic snapshots and nft additions (docs/10 part 1, T8.12a).
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 tests/stats/test.py
