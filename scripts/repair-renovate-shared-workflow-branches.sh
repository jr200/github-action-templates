#!/usr/bin/env bash
# Repair Renovate branches where generated shared workflows drift from the
# canonical sync-shared output. Renovate can update action refs inside copied
# consumer workflows, but those files are generated and drift-check rejects
# direct edits.

set -euo pipefail

base_ref="${1:-origin/${GITHUB_REF_NAME:-master}}"
branch_glob="${2:-renovate/*}"

if [[ -n "${RENOVATE_REPAIR_TOKEN:-}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
  git remote set-url origin "https://x-access-token:${RENOVATE_REPAIR_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
fi

git config user.name "${GIT_AUTHOR_NAME:-${GITHUB_ACTOR:-renovate}[bot]}"
git config user.email "${GIT_AUTHOR_EMAIL:-${GITHUB_ACTOR_ID:-41898282}+${GITHUB_ACTOR:-renovate}[bot]@users.noreply.github.com}"

git fetch --no-tags origin "+refs/heads/${branch_glob}:refs/remotes/origin/${branch_glob}"

base_sha="$(git rev-parse "$base_ref")"
repaired=0
checked=0

while IFS= read -r remote_ref; do
  branch="${remote_ref#refs/remotes/origin/}"
  [[ "$branch" == renovate/* ]] || continue

  changed_files="$(git diff --name-only "${base_sha}...${remote_ref}")"
  if ! grep -Eq '^\.github/(workflows/|\.shared-config\.ya?ml$)' <<<"$changed_files"; then
    continue
  fi

  checked=$((checked + 1))
  echo "repair-renovate-shared-workflow: checking ${branch}" >&2

  git checkout -B "$branch" "$remote_ref"

  if [ ! -x scripts/sync-shared ]; then
    echo "repair-renovate-shared-workflow: ${branch} has no executable scripts/sync-shared; skipping" >&2
    git checkout --detach "$base_sha" >/dev/null 2>&1 || true
    continue
  fi

  before_tree="$(git rev-parse HEAD^{tree})"
  ./scripts/sync-shared
  repair_paths=()
  [ -e .github/.shared-config.yaml ] && repair_paths+=(.github/.shared-config.yaml)
  [ -d .github/workflows ] && repair_paths+=(.github/workflows)

  if [ "${#repair_paths[@]}" -eq 0 ] || git diff --quiet -- "${repair_paths[@]}"; then
    echo "repair-renovate-shared-workflow: ${branch} did not need shared workflow changes" >&2
    git checkout --detach "$base_sha" >/dev/null 2>&1 || true
    continue
  fi

  git add "${repair_paths[@]}"
  git commit --amend --no-edit

  after_tree="$(git rev-parse HEAD^{tree})"
  if [[ "$before_tree" == "$after_tree" ]]; then
    echo "repair-renovate-shared-workflow: ${branch} tree unchanged after amend" >&2
    git checkout --detach "$base_sha" >/dev/null 2>&1 || true
    continue
  fi

  git push --force-with-lease origin "HEAD:${branch}"
  repaired=$((repaired + 1))
  git checkout --detach "$base_sha" >/dev/null 2>&1 || true
done < <(git for-each-ref --format='%(refname)' 'refs/remotes/origin/renovate')

git checkout --detach "$base_sha" >/dev/null 2>&1 || true
echo "repair-renovate-shared-workflow: checked=${checked} repaired=${repaired}" >&2
