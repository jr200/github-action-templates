#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

config="$ROOT/default.json"
report_linter="$ROOT/scripts/lint-renovate-report-problems.sh"
renovate_workflow="$ROOT/.github/workflows/renovate.yaml"

required_filters=(
    ".github/.shared-config.yaml"
    ".github/workflows/*.yaml"
    ".githooks/commit-msg"
    ".githooks/lint-message-text.sh"
    ".husky/commit-msg"
    "cog.toml"
    "commitlint.config.*"
    "package.json"
    "pnpm-lock.yaml"
    "scripts/sync-shared"
    "scripts/sync-shared-drift-check"
)

for filter in "${required_filters[@]}"; do
    if ! jq -e --arg filter "$filter" '
      .packageRules[]?
      | select((.matchPackageNames // []) | index("jr200-labs/github-action-templates"))
      | select((.groupSlug // "") == "shared-workflow-ref")
      | (.postUpgradeTasks.fileFilters // [])
      | index($filter)
    ' "$config" >/dev/null; then
        echo "missing shared-ref file filter: $filter" >&2
        exit 1
    fi
done

if ! jq -e '
  .packageRules[]?
  | select((.matchPackageNames // []) | index("jr200-labs/github-action-templates"))
  | select((.groupSlug // "") == "shared-workflow-ref")
  | (.postUpgradeTasks.commands // [])
  | any(contains("consumers/scripts/sync-shared") and contains(".github/.shared-config.yaml"))
' "$config" >/dev/null; then
    echo "shared-ref post-upgrade task must refresh scripts/sync-shared from the bumped shared ref before running it" >&2
    exit 1
fi

if ! jq -e '
  .packageRules[]?
  | select((.matchPackageNames // []) | index("jr200-labs/github-action-templates"))
  | select((.groupSlug // "") == "shared-workflow-ref")
  | (.postUpgradeTasks.commands // [])
  | any(contains("pnpm-lock.yaml") and contains("pnpm install --lockfile-only"))
' "$config" >/dev/null; then
    echo "shared-ref post-upgrade task must refresh pnpm-lock.yaml after package cleanup" >&2
    exit 1
fi

allowed_count=$(grep -c 'RENOVATE_ALLOWED_COMMANDS: .*consumers/scripts/sync-shared.*pnpm install --lockfile-only' "$renovate_workflow" || true)
if [ "$allowed_count" -ne 2 ]; then
    echo "renovate workflow must allow the shared-ref rollout command in both Renovate passes" >&2
    exit 1
fi

pnpm_setup_line=$(grep -n 'uses: pnpm/action-setup@' "$renovate_workflow" | head -n1 | cut -d: -f1 || true)
repair_line=$(grep -n 'repair-renovate-shared-workflow-branches.sh' "$renovate_workflow" | head -n1 | cut -d: -f1 || true)
if [ -z "$pnpm_setup_line" ] || [ -z "$repair_line" ] || [ "$pnpm_setup_line" -ge "$repair_line" ]; then
    echo "renovate workflow must install pnpm before repairing shared-ref branches" >&2
    exit 1
fi
if ! grep -A4 'uses: pnpm/action-setup@' "$renovate_workflow" | grep -q 'run_install: false'; then
    echo "renovate workflow pnpm setup must not install dependencies" >&2
    exit 1
fi

if [ ! -x "$report_linter" ]; then
    echo "missing executable Renovate report linter: $report_linter" >&2
    exit 1
fi

allowed_warning="$TMPDIR/allowed-warning.json"
cat > "$allowed_warning" <<'JSON'
{
  "repositories": [
    {
      "repository": "example/repo",
      "problems": [
        {
          "warnings": [
            "Cannot access vulnerability alerts. Please ensure permissions have been granted."
          ]
        }
      ]
    }
  ]
}
JSON
"$report_linter" "$allowed_warning"

allowed_pep440="$TMPDIR/allowed-pep440.json"
cat > "$allowed_pep440" <<'JSON'
{
  "repositories": [
    {
      "repository": "example/repo",
      "problems": [
        {
          "warnings": [
            "pep440: failed to calculate newValue"
          ]
        }
      ]
    }
  ]
}
JSON
"$report_linter" "$allowed_pep440"

real_error="$TMPDIR/real-error.json"
cat > "$real_error" <<'JSON'
{
  "repositories": [
    {
      "repository": "example/repo",
      "result": "lockfile-error",
      "problems": [
        {
          "msg": "artifact update failed"
        }
      ]
    }
  ]
}
JSON
if "$report_linter" "$real_error" >/tmp/renovate-report-linter.out 2>/tmp/renovate-report-linter.err; then
    echo "expected real Renovate error to fail" >&2
    exit 1
fi
grep -q "artifact update failed" /tmp/renovate-report-linter.err
