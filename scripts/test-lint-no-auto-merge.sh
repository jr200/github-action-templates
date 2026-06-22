#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

workflow_dir="$TMPDIR/workflows"
mkdir -p "$workflow_dir"

cat > "$workflow_dir/bad.yaml" <<'YAML'
name: bad
on:
  pull_request:
jobs:
  merge:
    runs-on: ubuntu-latest
    steps:
      - run: gh pr merge 123 --squash --auto
YAML

if "$ROOT/scripts/lint-no-auto-merge.sh" "$workflow_dir" >/tmp/lint-no-auto-merge-bad.out 2>/tmp/lint-no-auto-merge-bad.err; then
    echo "expected unannotated auto-merge to fail" >&2
    exit 1
fi
grep -q "forbidden auto-merge" /tmp/lint-no-auto-merge-bad.err

cat > "$workflow_dir/bad.yaml" <<'YAML'
name: allowed
on:
  pull_request:
jobs:
  merge:
    runs-on: ubuntu-latest
    steps:
      - run: gh pr merge 123 --squash --auto --delete-branch # lint-no-auto-merge:allow
YAML

"$ROOT/scripts/lint-no-auto-merge.sh" "$workflow_dir"
