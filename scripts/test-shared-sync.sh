#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

make_consumer_repo() {
    local repo_dir="$1"
    mkdir -p "$repo_dir/.github" "$repo_dir/scripts"
    cp "$ROOT/consumers/scripts/sync-shared" "$repo_dir/scripts/sync-shared"
    cat > "$repo_dir/.github/.shared-config.yaml" <<'YAML'
ref: shared-v0.1.0
workflows:
  - hygiene
YAML
}

consumer_repo="$TMPDIR/consumer"
make_consumer_repo "$consumer_repo"
(
    cd "$consumer_repo"
    git init -q
    SYNC_BASE_URL="file://$ROOT/consumers" ./scripts/sync-shared
    test -f .github/workflows/commitlint.yaml
    test -f .github/workflows/sync-shared-drift.yaml
    test -x .githooks/commit-msg
    test -f cog.toml
    test "$(git config --get core.hooksPath)" = ".githooks"
    STRICT=1 SYNC_BASE_URL="file://$ROOT/consumers" ./scripts/sync-shared --check
)

lint_repo="$TMPDIR/lint-consumer"
mkdir -p "$lint_repo/.github"
cp "$ROOT/shared/sync.sh" "$lint_repo/sync.sh"
cat > "$lint_repo/.github/.shared-config.yaml" <<'YAML'
ref: shared-v0.1.0
workflows:
  - hygiene
YAML
touch "$lint_repo/package.json"
cat > "$lint_repo/package.json" <<'JSON'
{}
JSON
cat > "$lint_repo/pnpm-workspace.yaml" <<'YAML'
packages:
  - "."
YAML
(
    cd "$lint_repo"
    git init -q
    SYNC_BASE_URL="file://$ROOT/shared" ./sync.sh node
    test -f .shared/eslint.config.mjs
    test -x .githooks/commit-msg
    test -f cog.toml
    test -f release-please-config.json
    test -f .syncpackrc.yaml
    test "$(git config --get core.hooksPath)" = ".githooks"
    ! grep -q '"prepare": "husky"' package.json
    grep -qx "packages:" pnpm-workspace.yaml
    grep -qx "minimumReleaseAge: 0" pnpm-workspace.yaml
)
