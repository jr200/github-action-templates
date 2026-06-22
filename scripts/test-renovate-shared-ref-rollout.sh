#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

config="$ROOT/default.json"
report_linter="$ROOT/scripts/lint-renovate-report-problems.sh"

required_filters=(
    ".github/.shared-config.yaml"
    ".github/workflows/*.yaml"
    ".githooks/commit-msg"
    ".githooks/lint-message-text.sh"
    "cog.toml"
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
