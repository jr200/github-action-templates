#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
caller="$ROOT/consumers/workflows/publish-npm-package.yaml"
reusable="$ROOT/.github/workflows/build_publish_npmjs.yaml"

grep -q 'preview-id:' "$caller"
grep -q 'preview-id: \${{ github.event.inputs.preview-id' "$caller"
grep -q 'PREVIEW_VERSION="${BASE_VERSION}-pr.${PREVIEW_ID}.${GITHUB_RUN_ID}.${GITHUB_RUN_ATTEMPT}"' "$reusable"
grep -q 'BASE_CMD="$BASE_CMD --tag preview"' "$reusable"
