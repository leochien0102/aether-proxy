#!/usr/bin/env bash
# Prepares an isolated worktree for one task card (docs/tasks/README.md "执行约定").
#
# Usage: bash tests/start-task.sh <card> [branch]
#   <card>    card id as written in docs/tasks/*.md, e.g. T0.3 or S1
#   [branch]  only needed when the card has no "**分支**：`...`" line
#
# Creates ../aether-proxy-wt/<card> on a new branch from the current local main
# (or reuses it if it already exists), builds the host ucode there and runs the
# baseline review. Safe to run from any directory.
set -eu

card="${1:-}"
if [ -z "$card" ]; then
	echo "usage: bash tests/start-task.sh <card> [branch]" >&2
	exit 2
fi

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
main_wt="$(git -C "$repo" worktree list --porcelain | sed -n '1s/^worktree //p')"
wt="$(dirname "$main_wt")/aether-proxy-wt/$card"

# Branch name: explicit argument, else the card's "**分支**：`...`" line.
branch="${2:-}"
if [ -z "$branch" ]; then
	branch="$(awk -v card="$card" '
		$0 ~ "^## " card "( |$)" { inside = 1; next }
		inside && /^## / { exit }
		inside && /\*\*分支\*\*/ { if (match($0, /`[^`]+`/)) { print substr($0, RSTART + 1, RLENGTH - 2); exit } }
	' "$main_wt"/docs/tasks/*.md)"
fi
if [ -z "$branch" ]; then
	echo "start-task: card $card has no **分支** line; pass the branch name as the second argument" >&2
	exit 2
fi

if [ -d "$wt" ]; then
	echo "start-task: reusing existing worktree $wt"
	actual="$(git -C "$wt" rev-parse --abbrev-ref HEAD)"
	if [ "$actual" != "$branch" ]; then
		echo "start-task: $wt is on branch '$actual', expected '$branch'" >&2
		exit 1
	fi
else
	if [ -n "$(git -C "$main_wt" status --porcelain)" ]; then
		echo "start-task: main checkout $main_wt has uncommitted changes; refusing to branch from it" >&2
		exit 1
	fi
	if git -C "$main_wt" rev-parse --verify -q "refs/heads/$branch" >/dev/null; then
		echo "start-task: branch '$branch' already exists without a worktree; remove it or pick another name" >&2
		exit 1
	fi
	mkdir -p "$(dirname "$wt")"
	git -C "$main_wt" worktree add -q "$wt" -b "$branch" main
	echo "start-task: created $wt on branch $branch (from local main $(git -C "$main_wt" rev-parse --short main))"
fi

cd "$wt"
bash tests/host/bootstrap.sh
echo
echo "== baseline review (a missing report is expected at this point)"
bash tests/review.sh || true

cat <<EOF

=====================================================================
 Task $card is ready.
 Work ONLY inside: $wt
 Branch:           $branch
 Do not edit $main_wt or any other repository under $(dirname "$main_wt").
=====================================================================
EOF
