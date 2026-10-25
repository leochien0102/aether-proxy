#!/usr/bin/env bash
# Previous-release clients against today's CLI (docs/08 "更新接口（固定）").
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
sha256sum -c tests/compat/frozen.sha256
node --test tests/compat/updates.test.js
