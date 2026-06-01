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
    SYNC_BASE_URL="file://$ROOT/consumers" ./scripts/sync-shared
    test -f .github/workflows/commitlint.yaml
    test -f .github/workflows/sync-shared-drift.yaml
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
(
    cd "$lint_repo"
    SYNC_BASE_URL="file://$ROOT/shared" ./sync.sh node
    test -f .shared/eslint.config.mjs
    test -f release-please-config.json
    test -f .syncpackrc.yaml
)
