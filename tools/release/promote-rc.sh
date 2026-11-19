#!/usr/bin/env bash
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
parse_args 'promote-rc.sh <rc-tag> [--dry-run]' "$@"
[[ $INPUT =~ $RC_RE ]] || die 'Expected a published RC tag'

mode=rc-gate-only
if "$DRY_RUN"; then mode=rc; fi
binding=$(verify "$mode" "$INPUT")
read -r SHA FORMAL_TAG <<< "$binding"
printf 'Prerelease %s is bound to %s\n' "$INPUT" "$SHA"
if "$DRY_RUN"; then
    promote "$INPUT"
    command_plan git push --porcelain origin "$SHA:refs/tags/$FORMAL_TAG"
    printf 'Wait for release-assets.yml (channel manifest path), then verify Release/RC SHA-256.\n'
    exit 0
fi

require_unused "$FORMAL_TAG"
check_push_origin
promote "$INPUT"
push_tag "$FORMAL_TAG"
wait_workflow "$APP_REPO" release-assets.yml push "$FORMAL_TAG"
verify compare "$FORMAL_TAG" "$INPUT"
