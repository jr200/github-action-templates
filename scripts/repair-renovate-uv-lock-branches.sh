#!/usr/bin/env bash
# Repair Renovate Python branches that changed pyproject.toml without uv.lock.
#
# This is a fallback for Renovate postUpgradeTasks edge cases. If Renovate
# updates Python dependencies but does not regenerate uv.lock, CI fails later at
# `uv lock --check`. Run this immediately after Renovate so the branch is fixed
# before reviewers or merge gates see a stale lockfile.

set -euo pipefail

base_ref="${1:-origin/${GITHUB_REF_NAME:-master}}"
branch_glob="${2:-renovate/*}"

if ! command -v uv >/dev/null 2>&1; then
  echo "repair-renovate-uv-lock: uv not found on PATH" >&2
  exit 2
fi

if [[ -n "${RENOVATE_REPAIR_TOKEN:-}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
  git remote set-url origin "https://x-access-token:${RENOVATE_REPAIR_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
fi

git fetch --no-tags origin "+refs/heads/${branch_glob}:refs/remotes/origin/${branch_glob}"

base_sha="$(git rev-parse "$base_ref")"
repaired=0
checked=0

while IFS= read -r remote_ref; do
  branch="${remote_ref#refs/remotes/origin/}"
  [[ "$branch" == renovate/* ]] || continue

  changed_files="$(git diff --name-only "${base_sha}...${remote_ref}")"
  if ! grep -qx 'pyproject.toml' <<<"$changed_files"; then
    continue
  fi
  if grep -qx 'uv.lock' <<<"$changed_files"; then
    continue
  fi

  checked=$((checked + 1))
  echo "repair-renovate-uv-lock: checking ${branch}" >&2

  git checkout -B "$branch" "$remote_ref"

  before_tree="$(git rev-parse HEAD^{tree})"
  uv lock

  if git diff --quiet -- uv.lock; then
    echo "repair-renovate-uv-lock: ${branch} did not need uv.lock changes" >&2
    git checkout --detach "$base_sha" >/dev/null 2>&1 || true
    continue
  fi

  git add uv.lock
  git commit --amend --no-edit

  after_tree="$(git rev-parse HEAD^{tree})"
  if [[ "$before_tree" == "$after_tree" ]]; then
    echo "repair-renovate-uv-lock: ${branch} tree unchanged after amend" >&2
    git checkout --detach "$base_sha" >/dev/null 2>&1 || true
    continue
  fi

  git push --force-with-lease origin "HEAD:${branch}"
  repaired=$((repaired + 1))
  git checkout --detach "$base_sha" >/dev/null 2>&1 || true
done < <(git for-each-ref --format='%(refname)' 'refs/remotes/origin/renovate')

git checkout --detach "$base_sha" >/dev/null 2>&1 || true
echo "repair-renovate-uv-lock: checked=${checked} repaired=${repaired}" >&2
