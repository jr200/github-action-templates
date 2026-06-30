#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

config="$ROOT/default.json"
report_linter="$ROOT/scripts/lint-renovate-report-problems.sh"
renovate_workflow="$ROOT/.github/workflows/renovate.yaml"

if jq -e '
  .packageRules[]?
  | select((.matchPackageNames // []) | index("jr200-labs/github-action-templates"))
  | select((.groupSlug // "") == "shared-workflow-ref")
  | has("postUpgradeTasks")
' "$config" >/dev/null; then
    echo "shared-ref rollout must use the reusable workflow repair step, not Renovate post-upgrade tasks" >&2
    exit 1
fi

if grep -q 'consumers/scripts/sync-shared.*pnpm install --lockfile-only' "$renovate_workflow"; then
    echo "renovate workflow must not allow the removed shared-ref post-upgrade command" >&2
    exit 1
fi

allowed_count=$(grep -c 'RENOVATE_ALLOWED_COMMANDS: .*\\./scripts/sync-shared' "$renovate_workflow" || true)
if [ "$allowed_count" -ne 2 ]; then
    echo "renovate workflow must allow the local sync-shared command in both Renovate passes" >&2
    exit 1
fi

if ! grep -q 'id: renovate-pass2' "$renovate_workflow"; then
    echo "renovate workflow must gate the second Renovate pass" >&2
    exit 1
fi
if ! grep -q 'select(.result? == "repository-changed")' "$renovate_workflow"; then
    echo "renovate pass 2 gate must be driven by the pass 1 repository-changed report result" >&2
    exit 1
fi
if ! grep -q "steps.renovate-pass2.outputs.run == 'true'" "$renovate_workflow"; then
    echo "renovate pass 2 must only run when the pass 1 gate says it is needed" >&2
    exit 1
fi
if ! grep -q "steps.renovate-pass2.outputs.run || 'false'" "$renovate_workflow"; then
    echo "renovate report validation must allow pass 2 to be skipped by the gate" >&2
    exit 1
fi

node_setup_line=$(grep -n 'uses: actions/setup-node@' "$renovate_workflow" | tail -n1 | cut -d: -f1 || true)
pnpm_setup_line=$(grep -n 'uses: pnpm/action-setup@' "$renovate_workflow" | tail -n1 | cut -d: -f1 || true)
cog_setup_line=$(grep -n 'uses: cocogitto/cocogitto-action@' "$renovate_workflow" | head -n1 | cut -d: -f1 || true)
repair_line=$(grep -n 'repair-renovate-shared-workflow-branches.sh' "$renovate_workflow" | head -n1 | cut -d: -f1 || true)
if [ -z "$node_setup_line" ] || [ -z "$pnpm_setup_line" ] || [ -z "$cog_setup_line" ] || [ -z "$repair_line" ] \
    || [ "$pnpm_setup_line" -ge "$node_setup_line" ] || [ "$node_setup_line" -ge "$cog_setup_line" ] || [ "$cog_setup_line" -ge "$repair_line" ]; then
    echo "renovate workflow must install pnpm, node, and cocogitto before repairing shared-ref branches" >&2
    exit 1
fi
if ! grep -q 'uses: actions/setup-node@v6' "$renovate_workflow"; then
    echo "renovate workflow must use the current setup-node action" >&2
    exit 1
fi
if ! grep -q 'uses: pnpm/action-setup@v6' "$renovate_workflow"; then
    echo "renovate workflow must install pnpm before repairing shared-ref branches" >&2
    exit 1
fi
if ! grep -A4 'uses: cocogitto/cocogitto-action@' "$renovate_workflow" | grep -q 'install-only: true'; then
    echo "renovate workflow cocogitto setup must be install-only" >&2
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
