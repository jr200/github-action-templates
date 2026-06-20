#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

bin="$tmp/bin"
capture="$tmp/capture"
mkdir -p "$bin" "$capture"

cat > "$bin/yq" <<'YQ'
#!/usr/bin/env bash
set -euo pipefail

query="$2"
case "$query" in
  "keys | .[]")
    echo "trunk-protect"
    ;;
  ".\"trunk-protect\" | keys | .[]")
    echo "whengas"
    echo "jr200-labs"
    ;;
  ".\"trunk-protect\".\"whengas\"")
    echo "org"
    ;;
  ".\"trunk-protect\".\"jr200-labs\"")
    echo "repo"
    ;;
  *)
    echo "unexpected yq query: $*" >&2
    exit 1
    ;;
esac
YQ
chmod +x "$bin/yq"

cat > "$bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail

if [ "$1" != "api" ]; then
  echo "unexpected gh command: $*" >&2
  exit 1
fi
shift

endpoint=""
method="GET"
input_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X|--method)
      shift
      method="$1"
      ;;
    --input)
      shift
      input_file="$1"
      ;;
    --jq|-q|--paginate|--silent)
      if [ "$1" = "--jq" ] || [ "$1" = "-q" ]; then
        shift
      fi
      ;;
    *)
      if [ -z "$endpoint" ]; then
        endpoint="$1"
      fi
      ;;
  esac
  shift
done

case "$method:$endpoint" in
  "GET:orgs/whengas/repos?per_page=100&type=all")
    echo "whengas-faker"
    ;;
  "GET:orgs/jr200-labs/repos?per_page=100&type=all")
    echo "public-repo"
    ;;
  "GET:/repos/whengas/whengas-faker/rulesets")
    true
    ;;
  "GET:/orgs/whengas/rulesets")
    echo "1"
    ;;
  "GET:/orgs/whengas/rulesets/1")
    cat "$TEST_RULESET_BODY"
    ;;
  "PUT:/orgs/whengas/rulesets/1")
    true
    ;;
  "GET:/repos/jr200-labs/public-repo/rulesets")
    echo "1"
    ;;
  "GET:/repos/whengas/whengas-faker/rulesets/1")
    cat "$TEST_RULESET_BODY"
    ;;
  "GET:/repos/jr200-labs/public-repo/rulesets/1")
    cat "$TEST_RULESET_BODY"
    ;;
  "GET:/repos/whengas/whengas-faker")
    printf '{"allow_auto_merge":false,"delete_branch_on_merge":true,"allow_update_branch":true}\n'
    ;;
  "GET:/repos/jr200-labs/public-repo")
    printf '{"allow_auto_merge":false,"delete_branch_on_merge":true,"allow_update_branch":true}\n'
    ;;
  "GET:/orgs/whengas/actions/permissions/fork-pr-workflows-private-repos")
    printf '{"run_workflows_from_fork_pull_requests":true,"send_write_tokens_to_workflows":true,"send_secrets_and_variables":true,"require_approval_for_fork_pr_workflows":true}\n'
    ;;
  "PUT:/orgs/whengas/actions/permissions/fork-pr-workflows-private-repos")
    cp "$input_file" "$TEST_CAPTURE_DIR/org-actions-policy.json"
    ;;
  "GET:/repos/jr200-labs/public-repo/actions/permissions/fork-pr-workflows-private-repos")
    printf '{"run_workflows_from_fork_pull_requests":true,"send_write_tokens_to_workflows":true,"send_secrets_and_variables":true,"require_approval_for_fork_pr_workflows":true}\n'
    ;;
  "PUT:/repos/jr200-labs/public-repo/actions/permissions/fork-pr-workflows-private-repos")
    cp "$input_file" "$TEST_CAPTURE_DIR/actions-policy.json"
    ;;
  *":/repos/whengas/whengas-faker/actions/permissions/fork-pr-workflows-private-repos")
    echo "whengas Actions policy must be reconciled at org scope only" >&2
    exit 1
    ;;
  *":/orgs/jr200-labs/actions/permissions/fork-pr-workflows-private-repos")
    echo "jr200-labs Actions policy must be reconciled at repo scope only" >&2
    exit 1
    ;;
  *)
    echo "unexpected gh api call: $method $endpoint" >&2
    exit 1
    ;;
esac
GH
chmod +x "$bin/gh"

PATH="$bin:$PATH" \
TEST_RULESET_BODY="$root/rulesets/trunk-protect.json" \
TEST_CAPTURE_DIR="$capture" \
  "$root/scripts/apply-rulesets.sh" --org whengas --repo whengas/whengas-faker --ruleset trunk-protect >"$tmp/apply-rulesets-actions-policy.out"

PATH="$bin:$PATH" \
TEST_RULESET_BODY="$root/rulesets/trunk-protect.json" \
TEST_CAPTURE_DIR="$capture" \
  "$root/scripts/apply-rulesets.sh" --org jr200-labs --repo jr200-labs/public-repo --ruleset trunk-protect >"$tmp/apply-rulesets-actions-policy-jr200.out"

org_payload="$capture/org-actions-policy.json"
repo_payload="$capture/actions-policy.json"
if [ ! -f "$org_payload" ]; then
  echo "expected org Actions private fork workflow approval payload to be written" >&2
  exit 1
fi
if [ ! -f "$repo_payload" ]; then
  echo "expected Actions private fork workflow approval payload to be written" >&2
  exit 1
fi

for payload in "$org_payload" "$repo_payload"; do
  jq -e '
  .run_workflows_from_fork_pull_requests == true and
  .send_write_tokens_to_workflows == true and
  .send_secrets_and_variables == true and
  .require_approval_for_fork_pr_workflows == false
  ' "$payload" >/dev/null
done

echo "test-apply-rulesets-actions-policy: ok"
