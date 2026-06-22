#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

bare="$tmp/origin.git"
work="$tmp/work"
bin="$tmp/bin"

mkdir -p "$bin"
cat > "$bin/uv" <<'UV'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != "lock" ]]; then
  echo "unexpected uv command: $*" >&2
  exit 2
fi
printf 'locked = true\n' > uv.lock
UV
chmod +x "$bin/uv"
export PATH="$bin:$PATH"

git init --bare "$bare" >/dev/null
git clone "$bare" "$work" >/dev/null 2>&1

cd "$work"
git config user.name tester
git config user.email tester@example.com

cat > pyproject.toml <<'PYPROJECT'
[project]
name = "demo"
version = "0.1.0"
dependencies = ["demo-dep>=1.0.0"]
PYPROJECT
cat > uv.lock <<'LOCK'
locked = false
LOCK
git add pyproject.toml uv.lock
git commit -m "initial" >/dev/null
git branch -M master
git push origin master >/dev/null 2>&1

git checkout -b renovate/python-dep >/dev/null
perl -0pi -e 's/demo-dep>=1\.0\.0/demo-dep>=1.0.1/' pyproject.toml
git add pyproject.toml
git commit -m "fix(deps): update python dependencies" >/dev/null
git push origin renovate/python-dep >/dev/null 2>&1

git checkout master >/dev/null

orphan_work="$tmp/orphan"
git clone "$bare" "$orphan_work" >/dev/null 2>&1
(
  cd "$orphan_work"
  git config user.name tester
  git config user.email tester@example.com
  git checkout --orphan renovate/no-merge-base >/dev/null
  git rm -rf . >/dev/null 2>&1 || true
  cat > pyproject.toml <<'PYPROJECT'
[project]
name = "orphan"
version = "0.1.0"
dependencies = ["orphan-dep>=1.0.1"]
PYPROJECT
  git add pyproject.toml
  git commit -m "fix(deps): update python dependencies" >/dev/null
  git push origin renovate/no-merge-base >/dev/null 2>&1
)

"$root/scripts/repair-renovate-uv-lock-branches.sh" origin/master 'renovate/*'

git fetch origin renovate/python-dep >/dev/null 2>&1
updated_lock="$(git show origin/renovate/python-dep:uv.lock)"
if [[ "$updated_lock" != "locked = true" ]]; then
  echo "expected renovate/python-dep uv.lock to be regenerated" >&2
  exit 1
fi

echo "test-repair-renovate-uv-lock-branches: ok"
