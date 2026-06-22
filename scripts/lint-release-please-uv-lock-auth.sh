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
cog_install_line="$(grep -n 'name: Install Cocogitto' "$workflow" | head -n1 | cut -d: -f1 || true)"
cog_verify_line="$(grep -n 'cog verify --file' "$workflow" | head -n1 | cut -d: -f1 || true)"
git_user_line="$(grep -n 'git config user.name' "$workflow" | head -n1 | cut -d: -f1 || true)"
git_email_line="$(grep -n 'git config user.email' "$workflow" | head -n1 | cut -d: -f1 || true)"

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

if [ -z "$cog_install_line" ] || [ -z "$cog_verify_line" ]; then
  echo "lint-release-please-uv-lock-auth: release Cocogitto verification step not found" >&2
  exit 1
fi

if [ -z "$git_user_line" ] || [ -z "$git_email_line" ]; then
  echo "lint-release-please-uv-lock-auth: release Cocogitto verification must configure git identity before cog verify" >&2
  exit 1
fi

if [ "$git_user_line" -le "$cog_install_line" ] || [ "$git_user_line" -ge "$cog_verify_line" ] \
  || [ "$git_email_line" -le "$cog_install_line" ] || [ "$git_email_line" -ge "$cog_verify_line" ]; then
  echo "lint-release-please-uv-lock-auth: git identity must be configured after Cocogitto install and before cog verify" >&2
  exit 1
fi

echo "lint-release-please-uv-lock-auth: $workflow OK"
