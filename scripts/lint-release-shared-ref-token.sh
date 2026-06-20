#!/usr/bin/env bash
# Ensure shared-ref releases use a GitHub App token with workflow permission.
# Tags that point at commits changing .github/workflows/* are rejected unless
# the pushing credential has workflows:write.

set -euo pipefail

workflow="${1:-.github/workflows/release-shared-ref.yaml}"

if [ ! -f "$workflow" ]; then
  echo "lint-release-shared-ref-token: workflow not found: $workflow" >&2
  exit 2
fi

if ! grep -q 'uses: actions/create-github-app-token@' "$workflow"; then
  echo "lint-release-shared-ref-token: release-shared-ref must mint a GitHub App token" >&2
  exit 1
fi

if ! grep -q 'permission-contents: write' "$workflow"; then
  echo "lint-release-shared-ref-token: app token must request contents:write" >&2
  exit 1
fi

if ! grep -q 'permission-workflows: write' "$workflow"; then
  echo "lint-release-shared-ref-token: app token must request workflows:write" >&2
  exit 1
fi

if ! grep -q 'token: \${{ steps.app-token.outputs.token }}' "$workflow"; then
  echo "lint-release-shared-ref-token: checkout must use the app token so tag pushes use workflows permission" >&2
  exit 1
fi

if ! grep -q 'GH_TOKEN: \${{ steps.app-token.outputs.token }}' "$workflow"; then
  echo "lint-release-shared-ref-token: gh release commands must use the app token" >&2
  exit 1
fi

if grep -q 'GH_TOKEN: \${{ github.token }}' "$workflow"; then
  echo "lint-release-shared-ref-token: release-shared-ref must not use github.token for releases" >&2
  exit 1
fi

echo "lint-release-shared-ref-token: $workflow OK"
