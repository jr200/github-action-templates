#!/usr/bin/env bash
# Repair Renovate branches whose manifest changed without pnpm-lock.yaml.

set -euo pipefail

base_ref="${1:-origin/${GITHUB_REF_NAME:-master}}"

if [[ -n "${RENOVATE_REPAIR_TOKEN:-}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
  git remote set-url origin "https://x-access-token:${RENOVATE_REPAIR_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
fi

git config user.name "${GIT_AUTHOR_NAME:-${GITHUB_ACTOR:-renovate}[bot]}"
git config user.email "${GIT_AUTHOR_EMAIL:-${GITHUB_ACTOR_ID:-41898282}+${GITHUB_ACTOR:-renovate}[bot]@users.noreply.github.com}"
git fetch --no-tags origin '+refs/heads/renovate/*:refs/remotes/origin/renovate/*'

base_sha="$(git rev-parse "$base_ref")"
checked=0
repaired=0

while IFS= read -r remote_ref; do
  branch="${remote_ref#refs/remotes/origin/}"
  changed_files="$(git diff --name-only "${base_sha}...${remote_ref}")"
  if ! grep -qE '(^|/)package\.json$' <<<"$changed_files" || grep -qx 'pnpm-lock.yaml' <<<"$changed_files"; then
    continue
  fi

  checked=$((checked + 1))
  git checkout -B "$branch" "$remote_ref"
  pnpm install --lockfile-only

  if git diff --quiet -- pnpm-lock.yaml; then
    git checkout --detach "$base_sha" >/dev/null 2>&1 || true
    continue
  fi

  git add pnpm-lock.yaml
  git commit --amend --no-edit
  git push --force-with-lease origin "HEAD:${branch}"
  repaired=$((repaired + 1))
  git checkout --detach "$base_sha" >/dev/null 2>&1 || true
done < <(git for-each-ref --format='%(refname)' 'refs/remotes/origin/renovate')

git checkout --detach "$base_sha" >/dev/null 2>&1 || true
echo "repair-renovate-pnpm-lock: checked=${checked} repaired=${repaired}" >&2
