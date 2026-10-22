#!/bin/sh
# Add controllable stderr locally; keep the shared job stub and its behavior unchanged.
if [ "$1" != job ] || [ "$2" != run ]; then
	printf '%s' "${JOB_STUB_STDERR:-}" >&2
fi
exec "$JOB_BASE_STUB" "$@"
