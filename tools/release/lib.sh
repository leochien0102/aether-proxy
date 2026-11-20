#!/usr/bin/env bash
# Shared helpers for the release entry point. All mutations are explicit.
set -euo pipefail
RELEASE_TOOLS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
APP_REPO=leochien0102/aether-proxy
CHANNEL_REPO=leochien0102/aether-proxy-channel
FORMAL_RE='^v[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+$'

die() { printf 'release: %s\n' "$*" >&2; exit 1; }
command_plan() { printf '+ '; printf '%q ' "$@"; printf '\n'; }
verify() { python3 "$RELEASE_TOOLS/verify.py" "$1" "$APP_REPO" "${@:2}"; }

parse_args() {
    local usage=$1
    shift
    [[ $# == 1 || ( $# == 2 && $2 == --dry-run ) ]] || die "Usage: $usage"
    [[ $1 != -* ]] || die "Usage: $usage"
    INPUT=$1
    DRY_RUN=false
    [[ $# == 1 ]] || DRY_RUN=true
    cd "$RELEASE_TOOLS/../.."
    command -v gh >/dev/null || die 'gh is required'
    if ! "$DRY_RUN"; then
        [[ -z $(git status --porcelain --untracked-files=normal) ]] || die 'Working tree must be clean'
    fi
}

remote_tags() {
    gh api --paginate "repos/$APP_REPO/git/matching-refs/tags/$1" --jq '.[].ref | sub("^refs/tags/"; "")'
}

remote_commit() {
    local tag=$1
    python3 -B - "$RELEASE_TOOLS" "$APP_REPO" "$tag" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from verify import commit_for
print(commit_for(sys.argv[2], sys.argv[3]))
PY
}

require_unused() {
    local remote
    remote=$(remote_tags "$1")
    if grep -Fxq "$1" <<< "$remote" || git show-ref --verify --quiet "refs/tags/$1"; then
        die "Tag already exists: $1; use the documented workflow recovery, not a new tag"
    fi
}

require_gate() {
    local result
    result=$(python3 "$RELEASE_TOOLS/gate.py" --sha "$SHA" --repo "$APP_REPO")
    GATE_RUN=$(printf '%s\n' "$result" | sed -n 's/^run_id=//p')
    [[ $GATE_RUN =~ ^[0-9]+$ ]] || die 'Invalid gate run ID'
    printf 'Gate run %s for %s\n' "$GATE_RUN" "$SHA"
}

resolve_version() {
    local makefile base rev tags requested=${INPUT#v}
    [[ $requested =~ ^[0-9]+\.[0-9]+\.[0-9]+(-r[0-9]+)?$ ]] || die 'Expected a version such as 1.2.1 or 1.2.1-r1'
    # A published historical tag is a read-only rehearsal, never a publish target.
    if "$DRY_RUN"; then
        tags=$(remote_tags "v$requested")
        if [[ $requested == *-r* ]]; then
            FORMAL_TAG=$(grep -Fx "v$requested" <<< "$tags" || :)
        else
            FORMAL_TAG=$(grep -Ex "v${requested//./\\.}-r[0-9]+" <<< "$tags" | sort -V | tail -n 1 || :)
        fi
        if [[ -n $FORMAL_TAG ]]; then
            [[ $(gh release view "$FORMAL_TAG" -R "$APP_REPO" --json isDraft,isPrerelease -q '.isDraft or .isPrerelease') == false ]]
            SHA=$(remote_commit "$FORMAL_TAG")
            return
        fi
    fi
    SHA=$(git rev-parse HEAD)
    makefile=$(git show "$SHA:aether-proxy/Makefile")
    base=$(printf '%s\n' "$makefile" | sed -n 's/^PKG_VERSION:=//p')
    rev=$(printf '%s\n' "$makefile" | sed -n 's/^PKG_RELEASE:=//p')
    FORMAL_TAG=v$base-r$rev
    [[ $FORMAL_TAG =~ $FORMAL_RE && ( $requested == "$base" || $requested == "$base-r$rev" ) ]] ||
        die "Requested version does not match HEAD ($FORMAL_TAG)"
    git show "$SHA:tests/compat/update-contract.json" | python3 -c '
import json, sys
contract = json.load(sys.stdin)
base = sys.argv[1]
if base not in contract["support_window"] or contract["clients"][base]["route"] != "direct":
    sys.exit("Release version missing from the direct support window")' "$base"
    [[ -n $(git show "$SHA:docs/releases/${FORMAL_TAG#v}.md") ]] || die 'Release notes missing or empty'
}

check_push_origin() {
    local url
    url=$(git remote get-url --push origin)
    case "$url" in
        "git@github.com:$APP_REPO"|"git@github.com:$APP_REPO.git"|"https://github.com/$APP_REPO"|"https://github.com/$APP_REPO.git") ;;
        *) die "Unexpected origin push URL: $url" ;;
    esac
}

push_tag() {
    check_push_origin
    # No local tag, no force, and no change to branches.
    local status
    command_plan git push --porcelain origin "$SHA:refs/tags/$1"
    status=$(git push --porcelain origin "$SHA:refs/tags/$1")
    printf '%s\n' "$status"
    grep -q $'^\\*\t' <<< "$status" || die "Git did not create a new tag: $1"
}

wait_workflow() {
    local repo=$1 workflow=$2 event=$3 selector=$4 query run id status conclusion
    local deadline=$((SECONDS + 1800))
    if [[ $event == push ]]; then
        query="head_sha=$SHA&event=push&per_page=100"
        selector=".head_sha == \"$SHA\" and .head_branch == \"$selector\""
    else
        query='event=workflow_dispatch&branch=main&per_page=100'
        selector=".display_title == \"$selector\""
    fi
    while (( SECONDS < deadline )); do
        run=$(timeout 30s gh api "repos/$repo/actions/workflows/$workflow/runs?$query" \
            --jq "[.workflow_runs[] | select($selector)] | first | select(. != null) | [.id, .status, (.conclusion // \"pending\")] | @tsv")
        if [[ -n $run ]]; then
            IFS=$'\t' read -r id status conclusion <<< "$run"
            if [[ $status == completed ]]; then
                printf '%s: https://github.com/%s/actions/runs/%s (%s)\n' "$workflow" "$repo" "$id" "$conclusion"
                [[ $conclusion == success ]] || die "$workflow run $id failed ($conclusion)"
                return
            fi
        fi
        sleep 10
    done
    die "Timed out waiting for $workflow ($selector)"
}

publish_channel() {
    local tag=$1 request_id
    local args=(gh workflow run publish-channel.yml -R "$CHANNEL_REPO" --ref main -f "release_tag=$tag")
    if "$DRY_RUN"; then
        command_plan "${args[@]}" -f dry_run=true
    else
        request_id=$(python3 -c 'from uuid import uuid4; print(uuid4().hex)')
        command_plan "${args[@]}" -f "request_id=$request_id"
        "${args[@]}" -f "request_id=$request_id"
        wait_workflow "$CHANNEL_REPO" publish-channel.yml workflow_dispatch "Publish channel $tag $request_id"
    fi
}
