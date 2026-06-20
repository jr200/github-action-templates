#!/usr/bin/env bash
# Reconcile org/repo rulesets to the canonical specs in rulesets/.
#
# Driven by rulesets/targets.yaml (which ruleset → which org → org-scope or
# per-repo-scope). Each ruleset's body lives in rulesets/<name>.json and is
# applied verbatim except for the org-vs-repo endpoint switch.
#
# Idempotent: if a ruleset with the same name already exists at the target,
# the script PUTs the canonical body to it (updating in place); otherwise
# POSTs a new one. Repo-level merge hygiene settings are also reconciled on
# every targeted repo:
#   - allow_auto_merge=false
#   - delete_branch_on_merge=true
#   - allow_update_branch=true
#   - require_approval_for_fork_pr_workflows=false
#
# Usage:
#   scripts/apply-rulesets.sh [--dry-run] [--org ORG] [--repo ORG/REPO]
#                             [--ruleset NAME] [--skip-auto-merge]
#
# Requires: gh, jq, yq. Env: gh authenticated as a token with admin on the
# target orgs/repos. Token plan must support the requested scope (org-level
# rulesets need GitHub Team).

set -euo pipefail

DRY_RUN=0
ORG_FILTER=""
RULESET_FILTER=""
SKIP_AUTO_MERGE=0
INTERACTIVE_ORG_SELECTION=0
APPLY_ORG_SCOPE=1
declare -a REPO_FILTERS=()
declare -a SUPPORTED_ORGS=("jr200-labs" "whengas" "janeway-labs")

usage() {
    sed -n '1,/^set -euo/p' "$0" | sed 's/^# \?//'
    cat <<'EOF'

Options:
  --dry-run            Print API calls instead of applying changes.
  --org <org>          Limit reconciliation to one supported org and prompt
                       Y/n (default Y) for each repo before applying repo-
                       scoped changes. For org-scoped rulesets, the script
                       prompts once before applying the org-wide rule.
  --ruleset <name>     Limit reconciliation to one ruleset from targets.yaml.
  --repo <org/repo>    Limit repo-scope reconciliation to one or more repos.
                       Repeat flag to target multiple repos.
  --skip-auto-merge    Skip PATCH allow_auto_merge=false enforcement.
  -h, --help           Show this help.

Examples:
  scripts/apply-rulesets.sh --org jr200-labs --dry-run
  scripts/apply-rulesets.sh --repo janeway-labs/translatepane --ruleset trunk-protect
  scripts/apply-rulesets.sh --org whengas
  scripts/apply-rulesets.sh --ruleset trunk-protect --repo jr200-labs/mem0-dashboard
EOF
}

org_supported() {
    local candidate="$1"
    local supported
    for supported in "${SUPPORTED_ORGS[@]}"; do
        if [ "$supported" = "$candidate" ]; then
            return 0
        fi
    done
    return 1
}

confirm_default_yes() {
    local prompt="$1"
    local reply

    if [ ! -t 0 ]; then
        return 0
    fi

    read -r -p "$prompt [Y/n] " reply || return 1
    case "$reply" in
        ""|[Yy]|[Yy][Ee][Ss]) return 0 ;;
        [Nn]|[Nn][Oo]) return 1 ;;
        *)
            echo "please answer Y or n" >&2
            confirm_default_yes "$prompt"
            ;;
    esac
}

interactive_select_repos() {
    local org="$1"
    local repos repo

    repos=$(gh api "orgs/$org/repos?per_page=100&type=all" --paginate --jq '.[] | select(.archived==false) | .name')
    while IFS= read -r repo; do
        [ -z "$repo" ] && continue
        if confirm_default_yes "apply to $org/$repo?"; then
            REPO_FILTERS+=("$org/$repo")
        fi
    done <<<"$repos"
}

repo_selected() {
    local org="$1" repo="$2"
    local fq="${org}/${repo}"
    local selected

    if [ "$INTERACTIVE_ORG_SELECTION" = 1 ] && [ "${#REPO_FILTERS[@]}" -eq 0 ]; then
        return 1
    fi

    if [ "${#REPO_FILTERS[@]}" -eq 0 ]; then
        return 0
    fi

    for selected in "${REPO_FILTERS[@]}"; do
        if [ "$selected" = "$fq" ]; then
            return 0
        fi
    done

    return 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)   DRY_RUN=1 ;;
        --org)       shift; ORG_FILTER="$1" ;;
        --org=*)     ORG_FILTER="${1#--org=}" ;;
        --ruleset)   shift; RULESET_FILTER="$1" ;;
        --ruleset=*) RULESET_FILTER="${1#--ruleset=}" ;;
        --repo)      shift; REPO_FILTERS+=("$1") ;;
        --repo=*)    REPO_FILTERS+=("${1#--repo=}") ;;
        --skip-auto-merge) SKIP_AUTO_MERGE=1 ;;
        -h|--help)   usage; exit 0 ;;
        *)           echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

if [ -n "$ORG_FILTER" ] && ! org_supported "$ORG_FILTER"; then
    echo "unsupported --org '$ORG_FILTER' (supported: ${SUPPORTED_ORGS[*]})" >&2
    exit 2
fi

if [ -n "$ORG_FILTER" ] && [ "${#REPO_FILTERS[@]}" -gt 0 ]; then
    for selected in "${REPO_FILTERS[@]}"; do
        case "$selected" in
            "$ORG_FILTER"/*) ;;
            *)
                echo "repo filter '$selected' does not match --org '$ORG_FILTER'" >&2
                exit 2
                ;;
        esac
    done
fi

for selected in "${REPO_FILTERS[@]}"; do
    case "$selected" in
        */*) ;;
        *)
            echo "invalid --repo '$selected' (expected ORG/REPO)" >&2
            exit 2
            ;;
    esac
done

if [ -n "$ORG_FILTER" ] && [ "${#REPO_FILTERS[@]}" -eq 0 ]; then
    INTERACTIVE_ORG_SELECTION=1
    interactive_select_repos "$ORG_FILTER"
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGETS="$REPO_ROOT/rulesets/targets.yaml"
RULESETS_DIR="$REPO_ROOT/rulesets"

for cmd in gh jq yq; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "missing: $cmd" >&2; exit 1; }
done

run() {
    if [ "$DRY_RUN" = 1 ]; then
        echo "DRY: $*"
    else
        "$@"
    fi
}

# Canonicalise a ruleset payload to a stable JSON string for comparison.
# Strips server-only fields (id/href/timestamps/etc.) and sorts keys.
canon_ruleset() {
    jq -Sc '{name, target, enforcement, conditions, rules, bypass_actors}'
}

# Compare canonical body to live; emit DRY: only when they differ.
diff_or_apply() {
    local label="$1" detail_endpoint="$2" body_file="$3"
    local live want
    live=$(gh api "$detail_endpoint" | jq -Sc '{name, target, enforcement, conditions, rules, bypass_actors}')
    want=$(canon_ruleset < "$body_file")
    if [ "$live" = "$want" ]; then
        echo "  $label: in sync"
        return
    fi
    echo "  $label: PUT (drift detected)"
    run gh api "$detail_endpoint" -X PUT --input "$body_file" --silent
}

# Apply one ruleset spec to one org at org scope.
apply_org() {
    local org="$1" name="$2" body_file="$3"
    local existing

    if [ "$INTERACTIVE_ORG_SELECTION" = 1 ] && [ "$APPLY_ORG_SCOPE" = 0 ]; then
        echo "  org/$org ruleset $name: skipped by prompt"
        return
    fi

    local tmp_body
    tmp_body=$(mktemp)
    # Organization rulesets require a repository targeting condition
    jq '.conditions += {"repository_name": {"include": ["~ALL"], "exclude": []}}' "$body_file" > "$tmp_body"

    existing=$(gh api "/orgs/$org/rulesets" --jq ".[] | select(.name==\"$name\") | .id" | head -1)
    if [ -n "$existing" ]; then
        diff_or_apply "org/$org ruleset $name (id=$existing)" "/orgs/$org/rulesets/$existing" "$tmp_body"
    else
        echo "  org/$org: POST ruleset $name (missing)"
        run gh api "/orgs/$org/rulesets" -X POST --input "$tmp_body" --silent
    fi
    rm -f "$tmp_body"
}

# If a ruleset is canonical at org scope, repo-level rulesets with the same
# name become accidental additive restrictions. Remove those duplicates so the
# org-level body is the single source of truth.
cleanup_repo_duplicates_for_org_ruleset() {
    local org="$1" name="$2"
    local repos

    repos=$(gh api "orgs/$org/repos?per_page=100&type=all" --paginate --jq '.[] | select(.archived==false) | .name')
    while IFS= read -r repo; do
        [ -z "$repo" ] && continue
        if ! repo_selected "$org" "$repo"; then
            continue
        fi
        local ids
        ids=$(gh api "/repos/$org/$repo/rulesets" --jq ".[] | select(.name==\"$name\" and .source_type==\"Repository\") | .id")
        while IFS= read -r id; do
            [ -z "$id" ] && continue
            echo "  repo/$org/$repo: DELETE duplicate repo-level ruleset $name (id=$id)"
            run gh api "/repos/$org/$repo/rulesets/$id" -X DELETE --silent
        done <<<"$ids"
    done <<<"$repos"
}

# Apply one ruleset spec to every non-archived repo in an org at repo scope.
apply_repo() {
    local org="$1" name="$2" body_file="$3"
    local repos
    repos=$(gh api "orgs/$org/repos?per_page=100&type=all" --paginate --jq '.[] | select(.archived==false) | .name')
    while IFS= read -r repo; do
        [ -z "$repo" ] && continue
        if ! repo_selected "$org" "$repo"; then
            continue
        fi
        local existing
        existing=$(gh api "/repos/$org/$repo/rulesets" --jq ".[] | select(.name==\"$name\") | .id" | head -1)
        if [ -n "$existing" ]; then
            diff_or_apply "repo/$org/$repo ruleset $name (id=$existing)" "/repos/$org/$repo/rulesets/$existing" "$body_file"
        else
            echo "  repo/$org/$repo: POST ruleset $name (missing)"
            run gh api "/repos/$org/$repo/rulesets" -X POST --input "$body_file" --silent
        fi
    done <<<"$repos"
}

# Reconcile repo-level Actions settings that don't live in rulesets.
# This keeps bot-repaired Renovate PRs from getting stuck behind the
# "approve workflow run" gate after github-actions[bot] amends a branch.
reconcile_actions_private_fork_workflow_policy() {
    local org="$1" repo="$2"
    local endpoint current approval tmp_body error_summary

    endpoint="/repos/$org/$repo/actions/permissions/fork-pr-workflows-private-repos"
    if ! current=$(gh api "$endpoint" 2>&1); then
        error_summary="${current//$'\n'/ }"
        echo "  repo/$org/$repo actions private fork workflow policy: skipped ($error_summary)"
        return
    fi

    approval=$(jq -r '.require_approval_for_fork_pr_workflows' <<<"$current")
    if [ "$approval" = "false" ]; then
        return
    fi

    tmp_body=$(mktemp)
    jq -S '
      {
        run_workflows_from_fork_pull_requests,
        send_write_tokens_to_workflows,
        send_secrets_and_variables,
        require_approval_for_fork_pr_workflows: false
      }
    ' <<<"$current" > "$tmp_body"

    echo "  repo/$org/$repo: reconcile require_approval_for_fork_pr_workflows=false (drift detected)"
    run gh api "$endpoint" -X PUT --input "$tmp_body" --silent
    rm -f "$tmp_body"
}

# Reconcile repo-level merge hygiene settings that don't live in rulesets.
# Rulesets cover branch protection / PR requirements; GitHub keeps a few
# adjacent behaviors as plain repository settings.
reconcile_repo_settings() {
    local org="$1"
    local repos

    if [ "$SKIP_AUTO_MERGE" = 1 ]; then
        echo "  org/$org: skipping repo merge-setting enforcement (--skip-auto-merge)"
    fi

    repos=$(gh api "orgs/$org/repos?per_page=100&type=all" --paginate --jq '.[] | select(.archived==false) | .name')
    while IFS= read -r repo; do
        [ -z "$repo" ] && continue
        if ! repo_selected "$org" "$repo"; then
            continue
        fi

        if [ "$SKIP_AUTO_MERGE" != 1 ]; then
            local current auto_merge delete_branch update_branch
            current=$(gh api "/repos/$org/$repo" -q '{allow_auto_merge: .allow_auto_merge, delete_branch_on_merge: .delete_branch_on_merge, allow_update_branch: .allow_update_branch}')
            auto_merge=$(jq -r '.allow_auto_merge' <<<"$current")
            delete_branch=$(jq -r '.delete_branch_on_merge' <<<"$current")
            update_branch=$(jq -r '.allow_update_branch' <<<"$current")

            if [ "$auto_merge" != "false" ] || [ "$delete_branch" != "true" ] || [ "$update_branch" != "true" ]; then
                echo "  repo/$org/$repo: reconcile allow_auto_merge=false, delete_branch_on_merge=true, allow_update_branch=true (drift detected)"
                run gh api -X PATCH "/repos/$org/$repo" \
                    -F allow_auto_merge=false \
                    -F delete_branch_on_merge=true \
                    -F allow_update_branch=true \
                    --silent
            fi
        fi

        reconcile_actions_private_fork_workflow_policy "$org" "$repo"
    done <<<"$repos"
}

# Iterate targets.yaml.
rulesets=$(yq -r 'keys | .[]' "$TARGETS")
while IFS= read -r ruleset; do
    [ -z "$ruleset" ] && continue
    [ -n "$RULESET_FILTER" ] && [ "$ruleset" != "$RULESET_FILTER" ] && continue
    body="$RULESETS_DIR/$ruleset.json"
    [ -f "$body" ] || { echo "missing body file: $body" >&2; exit 1; }

    echo "=== ruleset: $ruleset ==="
    orgs=$(yq -r ".\"$ruleset\" | keys | .[]" "$TARGETS")
    while IFS= read -r org; do
        [ -z "$org" ] && continue
        [ -n "$ORG_FILTER" ] && [ "$org" != "$ORG_FILTER" ] && continue
        scope=$(yq -r ".\"$ruleset\".\"$org\"" "$TARGETS")

        if [ "$INTERACTIVE_ORG_SELECTION" = 1 ] && [ "$scope" = "org" ]; then
            if [ "${#REPO_FILTERS[@]}" -eq 0 ]; then
                echo "  org/$org: no repos selected; skipping org-scoped ruleset $ruleset"
                APPLY_ORG_SCOPE=0
            elif confirm_default_yes "apply org-scoped ruleset '$ruleset' to all repos in $org?"; then
                APPLY_ORG_SCOPE=1
            else
                APPLY_ORG_SCOPE=0
            fi
        fi

        case "$scope" in
            org)
                apply_org  "$org" "$ruleset" "$body"
                cleanup_repo_duplicates_for_org_ruleset "$org" "$ruleset"
                ;;
            repo) apply_repo "$org" "$ruleset" "$body" ;;
            *) echo "unknown scope '$scope' for $ruleset/$org" >&2; exit 1 ;;
        esac
        reconcile_repo_settings "$org"
    done <<<"$orgs"
done <<<"$rulesets"

echo "done."
