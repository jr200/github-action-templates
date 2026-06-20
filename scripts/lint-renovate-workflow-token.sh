#!/usr/bin/env bash
# Renovate may update generated .github/workflows/* files after post-upgrade
# sync. The GitHub App token used for Renovate branches must include
# workflows:write or GitHub rejects those pushes.

set -euo pipefail

workflow="${1:-.github/workflows/renovate.yaml}"

if [ ! -f "$workflow" ]; then
  echo "lint-renovate-workflow-token: workflow not found: $workflow" >&2
  exit 2
fi

if ! grep -q 'uses: actions/create-github-app-token@' "$workflow"; then
  echo "lint-renovate-workflow-token: Renovate workflow must mint a GitHub App token" >&2
  exit 1
fi

if ! grep -q 'permission-contents: write' "$workflow"; then
  echo "lint-renovate-workflow-token: app token must request contents:write" >&2
  exit 1
fi

if ! grep -q 'permission-pull-requests: write' "$workflow"; then
  echo "lint-renovate-workflow-token: app token must request pull-requests:write" >&2
  exit 1
fi

if ! grep -q 'permission-issues: write' "$workflow"; then
  echo "lint-renovate-workflow-token: app token must request issues:write" >&2
  exit 1
fi

if ! grep -q 'permission-workflows: write' "$workflow"; then
  echo "lint-renovate-workflow-token: app token must request workflows:write" >&2
  exit 1
fi

echo "lint-renovate-workflow-token: $workflow OK"
