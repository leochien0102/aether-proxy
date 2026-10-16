#!/bin/sh
# Test double for /etc/init.d/aether-proxy, used only by tests/rpcd
# (docs/tasks/m8.md T8.1). Selected through AETHER_PROXY_TEST_RPCD_INIT, so the
# real init script is never executed. Records the received action to
# RPCD_TEST_INIT_LOG and then sleeps RPCD_TEST_INIT_SLEEP seconds (default 0),
# so the tests can prove that the rpcd plugin backgrounds the service action
# instead of waiting for it to finish.

LOG="${RPCD_TEST_INIT_LOG:?RPCD_TEST_INIT_LOG not set}"

printf 'ACTION=%s\n' "$1" >> "$LOG"
sleep "${RPCD_TEST_INIT_SLEEP:-0}"
