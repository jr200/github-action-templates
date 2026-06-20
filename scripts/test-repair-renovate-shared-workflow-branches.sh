#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

bare="$tmp/origin.git"
work="$tmp/work"

git init --bare "$bare" >/dev/null
git clone "$bare" "$work" >/dev/null 2>&1

cd "$work"
git config user.name tester
git config user.email tester@example.com

mkdir -p .github/workflows scripts
cat > pyproject.toml <<'PYPROJECT'
[project]
name = "demo"
version = "0.1.0"
dependencies = ["demo-dep>=1.0.0"]
PYPROJECT
cat > .github/workflows/drift-check.yaml <<'WORKFLOW'
# GENERATED/SHARED WORKFLOW: copied into consuming repos by sync-shared.
steps:
  - uses: actions/checkout@v6
WORKFLOW
cat > scripts/sync-shared <<'SYNC'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p .github/workflows
cat > .github/workflows/drift-check.yaml <<'WORKFLOW'
# GENERATED/SHARED WORKFLOW: copied into consuming repos by sync-shared.
steps:
  - uses: actions/checkout@v6
WORKFLOW
SYNC
chmod +x scripts/sync-shared

git add .github/workflows/drift-check.yaml pyproject.toml scripts/sync-shared
git commit -m "initial" >/dev/null
git branch -M master
git push origin master >/dev/null 2>&1

git checkout -b renovate/demo >/dev/null
perl -0pi -e 's/demo-dep>=1\.0\.0/demo-dep>=1.0.1/' pyproject.toml
perl -0pi -e 's/actions\/checkout\@v6/actions\/checkout\@v7/' .github/workflows/drift-check.yaml
git add .github/workflows/drift-check.yaml pyproject.toml
git commit -m "fix(deps): update github-actions" >/dev/null
git push origin renovate/demo >/dev/null 2>&1

git checkout master >/dev/null

"$root/scripts/repair-renovate-shared-workflow-branches.sh" origin/master 'renovate/*'

git fetch origin renovate/demo >/dev/null 2>&1
updated_workflow="$(git show origin/renovate/demo:.github/workflows/drift-check.yaml)"
if grep -q 'actions/checkout@v7' <<<"$updated_workflow"; then
  echo "expected renovate/demo workflow drift to be repaired" >&2
  exit 1
fi
if ! grep -q 'actions/checkout@v6' <<<"$updated_workflow"; then
  echo "expected renovate/demo workflow to contain canonical checkout@v6" >&2
  exit 1
fi

echo "test-repair-renovate-shared-workflow-branches: ok"
