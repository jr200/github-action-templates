#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <report.json> [report.json...]" >&2
  exit 2
fi

allowed_vulnerability_warning='Cannot access vulnerability alerts. Please ensure permissions have been granted.'
allowed_pep440_warning='pep440: failed to calculate newValue'
fail=0

for report in "$@"; do
  if [ ! -f "$report" ]; then
    echo "Renovate report missing: $report" >&2
    fail=1
    continue
  fi

  problems=$(jq -r --arg allowed_vulnerability "$allowed_vulnerability_warning" --arg allowed_pep440 "$allowed_pep440_warning" '
    [.problems[]?, .repositories[]?.problems[]?] as $p
    | ($p | map(.msg)) + ($p | map(.warnings // [] | .[])) + ($p | map(.errors // [] | .[]))
    | map(select(. != null and . != $allowed_vulnerability and . != $allowed_pep440))
    | unique
    | .[]
  ' "$report")

  results=$(jq -r '
    .. | objects
    | select(has("result"))
    | select(.result // "" | test("error"))
    | "result=\(.result) on repository=\(.repository // "?")"
  ' "$report")

  if [ -n "${problems:-}" ] || [ -n "${results:-}" ]; then
    echo "Renovate problems in $report:" >&2
    [ -n "${problems:-}" ] && printf '%s\n' "$problems" >&2
    [ -n "${results:-}" ] && printf '%s\n' "$results" >&2
    fail=1
  fi
done

exit "$fail"
