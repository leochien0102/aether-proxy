#!/bin/bash
# Check that a branch changes comments only (T8.14, docs/tasks/m8.md): every added or removed
# line in the diff against the base must be blank or a whole-line comment, so no behaviour can
# change. A trailing comment on a code line counts as a code change; put comments on their own line.
#
# Usage: bash tests/comment-only.sh [base]   (base defaults to main)
set -u
base=${1:-main}
cd "$(git rev-parse --show-toplevel)" || exit 2

fail=0
# Whole-line comments in ucode, JS and sh: //, /*, *, */ and # (but not #! on the first line).
comment='^[[:space:]]*(//|/\*|\*|\*/|#[^!]|#$|$)'

while IFS= read -r file; do
	case "$file" in
		reports/*) continue ;;
	esac
	bad=$(git diff -U0 "$base"...HEAD -- "$file" | grep -E '^[+-]' | grep -vE '^(\+\+\+|---) ' |
		cut -c2- | grep -vE "$comment")
	if [ -n "$bad" ]; then
		echo "FAIL  $file changes non-comment lines:"
		printf '%s\n' "$bad" | head -5 | sed 's/^/        /'
		fail=1
	fi
done < <(git diff --name-only "$base"...HEAD)

[ "$fail" -eq 0 ] && echo "PASS  only comment lines changed against $base"
exit "$fail"
