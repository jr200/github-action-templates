#!/usr/bin/env bash
# Force-rebase Renovate branches for the explicit manual recovery lane.

set -euo pipefail

base_ref="${1:-origin/${GITHUB_REF_NAME:-master}}"

if [[ -n "${RENOVATE_REPAIR_TOKEN:-}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
  git remote set-url origin "https://x-access-token:${RENOVATE_REPAIR_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
fi

git config user.name "${GIT_AUTHOR_NAME:-${GITHUB_ACTOR:-renovate}[bot]}"
git config user.email "${GIT_AUTHOR_EMAIL:-${GITHUB_ACTOR_ID:-41898282}+${GITHUB_ACTOR:-renovate}[bot]@users.noreply.github.com}"

if [[ "$(git rev-parse --is-shallow-repository)" == true ]]; then
  git fetch --no-tags --unshallow origin
fi
git fetch --no-tags origin '+refs/heads/renovate/*:refs/remotes/origin/renovate/*'

base_sha="$(git rev-parse "$base_ref")"
checked=0
rebased=0
failed=0

while IFS= read -r remote_ref; do
  branch="${remote_ref#refs/remotes/origin/}"
  checked=$((checked + 1))

  if git merge-base --is-ancestor "$base_sha" "$remote_ref"; then
    continue
  fi

  git checkout -B "$branch" "$remote_ref"
  if git rebase -X theirs "$base_sha"; then
    git push --force-with-lease origin "HEAD:${branch}"
    rebased=$((rebased + 1))
  else
    git rebase --abort || true
    echo "repair-renovate-rebase: ${branch} could not be rebased" >&2
    failed=$((failed + 1))
  fi
  git checkout --detach "$base_sha" >/dev/null 2>&1 || true
done < <(git for-each-ref --format='%(refname)' 'refs/remotes/origin/renovate')

git checkout --detach "$base_sha" >/dev/null 2>&1 || true
echo "repair-renovate-rebase: checked=${checked} rebased=${rebased} failed=${failed}" >&2
