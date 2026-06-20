#!/usr/bin/env bash
# Ensure release-please refreshes uv.lock with GitHub auth available to uv's
# internal git fetches. Private git dependencies fail without this.

set -euo pipefail

workflow="${1:-.github/workflows/release_please.yaml}"

if [ ! -f "$workflow" ]; then
  echo "lint-release-please-uv-lock-auth: workflow not found: $workflow" >&2
  exit 2
fi

refresh_line="$(grep -n 'name: Refresh uv.lock on release PR' "$workflow" | head -n1 | cut -d: -f1 || true)"
uv_lock_line="$(grep -n '^[[:space:]]*uv lock$' "$workflow" | head -n1 | cut -d: -f1 || true)"
auth_line="$(grep -n "machine github.com" "$workflow" | head -n1 | cut -d: -f1 || true)"

if [ -z "$refresh_line" ] || [ -z "$uv_lock_line" ]; then
  echo "lint-release-please-uv-lock-auth: release uv.lock refresh step not found" >&2
  exit 1
fi

if [ -z "$auth_line" ]; then
  echo "lint-release-please-uv-lock-auth: release uv.lock refresh does not configure GitHub HTTPS auth before uv lock" >&2
  exit 1
fi

if [ "$auth_line" -le "$refresh_line" ] || [ "$auth_line" -ge "$uv_lock_line" ]; then
  echo "lint-release-please-uv-lock-auth: GitHub HTTPS auth must be configured inside the refresh step before uv lock" >&2
  exit 1
fi

echo "lint-release-please-uv-lock-auth: $workflow OK"
