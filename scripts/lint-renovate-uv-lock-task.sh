#!/usr/bin/env bash
# Validate the shared Renovate uv.lock regeneration rule.
#
# Renovate applies postUpgradeTasks from the matched dependency config. In
# grouped Python PRs, scoping this rule with matchFileNames has failed to attach
# the task to pyproject.toml updates, leaving uv.lock stale while CI rejects the
# branch with `uv lock --check`.

set -euo pipefail

file="${1:-default.json}"
workflow="${2:-.github/workflows/renovate.yaml}"

if [[ ! -f "$file" ]]; then
  echo "ERROR: config file not found: $file" >&2
  exit 2
fi

if [[ ! -f "$workflow" ]]; then
  echo "ERROR: workflow file not found: $workflow" >&2
  exit 2
fi

if ! jq -e . "$file" >/dev/null 2>&1; then
  echo "ERROR: $file is not valid JSON" >&2
  exit 2
fi

rule_count=$(jq '
  [
    .packageRules[]?
    | select((.postUpgradeTasks.commands // []) == ["uv lock"])
    | select((.postUpgradeTasks.installTools // {}) == {"python": {}, "uv": {}})
    | select((.postUpgradeTasks.fileFilters // []) == ["uv.lock"])
    | select((.matchManagers // []) | index("pep621"))
    | select((.matchManagers // []) | index("custom.regex"))
  ]
  | length
' "$file")

if [[ "$rule_count" != "1" ]]; then
  echo "FAIL: expected exactly one uv.lock postUpgradeTasks rule for pep621/custom.regex managers with installTools.python and installTools.uv; found ${rule_count}" >&2
  exit 1
fi

file_scoped_count=$(jq '
  [
    .packageRules[]?
    | select((.postUpgradeTasks.commands // []) == ["uv lock"])
    | select(has("matchFileNames"))
  ]
  | length
' "$file")

if [[ "$file_scoped_count" != "0" ]]; then
  echo "FAIL: uv.lock postUpgradeTasks rule must not use matchFileNames; it can prevent Renovate from running the task on grouped pyproject.toml updates" >&2
  exit 1
fi

shared_ref_uv_lock_count=$(jq '
  [
    .packageRules[]?
    | select((.postUpgradeTasks.commands // []) == ["uv lock"])
    | select(((.matchPackageNames // []) | index("!jr200-labs/github-action-templates")) | not)
  ]
  | length
' "$file")

if [[ "$shared_ref_uv_lock_count" != "0" ]]; then
  echo "FAIL: uv.lock postUpgradeTasks rule must exclude the shared workflow ref package with negative matchPackageNames; shared-ref repos are not necessarily Python projects" >&2
  exit 1
fi

if ! awk '
  /uses: astral-sh\/setup-uv@/ { in_setup = 1; next }
  in_setup && /^[^[:space:]-]/ { in_setup = 0 }
  in_setup && /^[[:space:]]+version:[[:space:]]*[^[:space:]]+/ { found = 1 }
  END { exit found ? 0 : 1 }
' "$workflow"; then
  echo "FAIL: Renovate setup-uv step must pin version so self-hosted runners do not need latest-version discovery" >&2
  exit 1
fi

echo "lint-renovate-uv-lock-task: ok" >&2
