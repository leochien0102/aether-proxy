#!/usr/bin/env bash
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
parse_args 'release.sh <version> [--dry-run]' "$@"
resolve_version
require_gate

if "$DRY_RUN"; then
    command_plan git push --porcelain origin "$SHA:refs/tags/$FORMAL_TAG"
    command_plan gh workflow run release-assets.yml -R "$APP_REPO" --ref main -f "tag=$FORMAL_TAG" -f dry_run=true
    printf 'Direct staging would select 18 packages from gate %s and verify SHA256SUMS.\n' "$GATE_RUN"
    publish_channel "$FORMAL_TAG"
    printf '写通道 dry-run：预览 current/previous 和 24 个矩阵槽位的 SHA-256 对照。\n'
    exit 0
fi

require_unused "$FORMAL_TAG"
[[ $(verify stable-matches "$FORMAL_TAG") == no ]] || die 'Stable already has this version; see the release checklist for recovery'
push_tag "$FORMAL_TAG"
wait_workflow "$APP_REPO" release-assets.yml push "$FORMAL_TAG"
publish_channel "$FORMAL_TAG"
verify compare "$FORMAL_TAG"
