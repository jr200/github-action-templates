#!/usr/bin/env bash
# Lint GitHub Actions workflows for forbidden auto-merge / auto-approve
# patterns. The branch ruleset gate is only a real gate if no workflow can
# sidestep it. This lint catches any consumer that grew a `gh pr merge` /
# `--auto-merge` / `gh pr review --approve` sneak path before it lands.
#
# Forbidden patterns (regex-tested against every line in
# .github/workflows/*.y[a]ml):
#
#   gh pr merge                  — any direct merge invocation
#   gh pr review .* --approve    — bot self-approval
#   --auto-merge                 — gh CLI auto-merge flag
#   --auto                       — flag on `gh pr merge --auto` form
#   peter-evans/enable-pull-request-automerge  — common third-party
#   pascalgn/automerge-action                  — common third-party
#
# Usage:
#   lint-no-auto-merge.sh [<workflows-dir>]
#     default: .github/workflows
#
# Exit codes:
#   0 no forbidden patterns
#   1 one or more matches found
#   2 workflows dir missing

set -euo pipefail

dir="${1:-.github/workflows}"

if [[ ! -d "$dir" ]]; then
  echo "ERROR: workflows dir not found: $dir" >&2
  exit 2
fi

shopt -s nullglob
files=("$dir"/*.yaml "$dir"/*.yml)
if [[ ${#files[@]} -eq 0 ]]; then
  echo "no workflow files in $dir — nothing to lint"
  exit 0
fi

# One alternation regex. Use extended grep rather than GNU-only `grep -P`
# because maintainers run this script on macOS as well as Linux runners.
pattern='gh pr merge([[:space:]]|$)|gh pr review[^|]*--approve([[:space:]]|$)|--auto-merge([[:space:]]|$)|gh pr merge[^|]*--auto([[:space:]]|$)|peter-evans/enable-pull-request-automerge|pascalgn/automerge-action'

# Allow lines explicitly opted-in via trailing "# lint-no-auto-merge:allow".
hits=$(grep -nE "$pattern" "${files[@]}" 2>/dev/null | grep -v 'lint-no-auto-merge:allow' || true)

if [[ -n "$hits" ]]; then
  echo "ERROR: forbidden auto-merge / auto-approve patterns found:" >&2
  echo "$hits" >&2
  echo >&2
  echo "Merges must be performed by a human reviewer (WG-105)." >&2
  echo "If a specific line is intentional, append \"# lint-no-auto-merge:allow\" — and document why in the PR." >&2
  exit 1
fi

echo "no auto-merge / auto-approve patterns found in $dir"
