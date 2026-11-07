#!/usr/bin/env bash
# T15.5 standalone gate contracts; lifecycle integrations are separately labelled.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
python3 tests/xray-ready/run.py
python3 tests/xray-ready/lifecycle.py
