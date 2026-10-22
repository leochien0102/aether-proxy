#!/bin/sh
# Record exact argv without changing the existing curl substitute's behavior (T9.17).
printf '%s\n' "$@" >> "$SYSROOT/curl-argv.log"
exec "${0%/*}/curl-body" "$@"
