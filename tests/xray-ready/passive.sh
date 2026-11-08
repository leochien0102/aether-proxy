#!/usr/bin/env bash
# T15.7: real kernel/listener proof followed by controlled transport faults.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 tests/xray-ready/passive.py
