#!/usr/bin/env bash
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
parse_args 'rc.sh <version> [--dry-run]' "$@"

if [[ $INPUT == 0.0.0-dryrun ]]; then
    "$DRY_RUN" || die '0.0.0-dryrun is a plan-only example'
    sample=$(gh release view -R "$APP_REPO" --json tagName -q .tagName)
    [[ $sample =~ $FORMAL_RE ]] || die 'No formal release available for rehearsal'
    SHA=$(remote_commit "$sample")
    FORMAL_TAG=v0.0.0-r1
    printf 'Synthetic tag plan: use the gate of %s only to demonstrate the selection.\n' "$sample"
else
    resolve_version
fi
require_gate
if ! "$DRY_RUN"; then require_unused "$FORMAL_TAG"; fi
refs=$(remote_tags "$FORMAL_TAG-rc")
refs+=$'\n'$(git tag --list "$FORMAL_TAG-rc*")
latest=$(printf '%s\n' "$refs" | grep -E "^${FORMAL_TAG//./\\.}-rc[1-9][0-9]*$" | sort -V | tail -n 1 || :)
latest=${latest##*-rc}
tag=$FORMAL_TAG-rc$((${latest:-0} + 1))
require_unused "$tag"
if "$DRY_RUN"; then
    command_plan git push --porcelain origin "$SHA:refs/tags/$tag"
    printf 'Wait for release-candidate.yml (%s), then verify the gate-only prerelease.\n' "$tag"
    rc_inventory_plan
    promote "$tag" rc
    printf 'Wait for persistent channel-rc and print its 24 package hashes; do not publish to stable.\n'
    exit 0
fi

push_tag "$tag"
wait_workflow "$APP_REPO" release-candidate.yml push "$tag"
verify rc-gate-only "$tag"
gh release view "$tag" -R "$APP_REPO" --json url,assets --jq '.url, .assets[].name'
promote "$tag" rc
verify rc-channel "$tag"
