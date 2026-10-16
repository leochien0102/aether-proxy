#!/bin/sh
# Test double for the aether-proxy command line, used only by tests/rpcd
# (docs/tasks/m8.md T8.1). Selected through AETHER_PROXY_TEST_RPCD_CLI, so the
# real binary is never executed. Every received argument is appended to
# RPCD_TEST_CLI_LOG (one ARG=<arg> line each, then "---") so the tests can
# assert exactly what the rpcd plugin forwarded. Behavior comes from the
# tab-separated control file named by RPCD_TEST_CTRL, which the test rewrites
# between scenarios:
#   exit     process exit code (default 0)
#   stdout   text written to stdout, plus a trailing newline
#   stderr   text written to stderr, plus a trailing newline
#   sleep    seconds to sleep before answering

CTRL="${RPCD_TEST_CTRL:?RPCD_TEST_CTRL not set}"
LOG="${RPCD_TEST_CLI_LOG:?RPCD_TEST_CLI_LOG not set}"

value() {
	while IFS="	" read -r k v; do
		if [ "$k" = "$1" ]; then
			printf '%s' "$v"
			return
		fi
	done < "$CTRL"
}

for arg do
	# base64 keeps multi-line arguments (save_file content) intact in the log;
	# the test decodes ARG64 lines back to the original argument.
	printf 'ARG64=%s\n' "$(printf '%s' "$arg" | base64 -w0)" >> "$LOG"
done
printf -- '---\n' >> "$LOG"

delay="$(value sleep)"
[ -n "$delay" ] && sleep "$delay"

out="$(value stdout)"
[ -n "$out" ] && printf '%s\n' "$out"

err="$(value stderr)"
[ -n "$err" ] && printf '%s\n' "$err" >&2

code="$(value exit)"
exit "${code:-0}"
