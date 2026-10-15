#!/bin/sh
set -eu

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
	printf 'usage: %s <manifest.json> <secret-key> [public-key]\n' "$0" >&2
	exit 2
fi

manifest=$1
secret_key=$2
public_key=${3-}
usign -S -m "$manifest" -s "$secret_key"
if [ -n "$public_key" ]; then
	usign -V -q -m "$manifest" -p "$public_key"
fi
