#!/bin/bash
# T15.4: no privileged/global DNS services; only dynamically allocated loopback endpoints.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 tests/bootstrap-dns/suite.py "$@"
