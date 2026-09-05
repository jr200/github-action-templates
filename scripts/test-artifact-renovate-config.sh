#!/usr/bin/env bash
set -euo pipefail

root=$(git rev-parse --show-toplevel)
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

cat > "$tmpdir/artifacts.yaml" <<'YAML'
version: 1
artifacts:
  - component: api
    publisher: docker
    type: docker
    name: ghcr.io/whengas/api
    renovate:
      repository: whengas/whengas-iac
      dependencies:
        - whengas/api
  - component: api
    publisher: npm
    type: npm
    name: "@whengas/api"
    renovate:
      repository: whengas/whengas-iac
      dependencies:
        - "@whengas/api"
YAML

docker=$($root/scripts/resolve-artifact-renovate.sh "$tmpdir/artifacts.yaml" docker api)
jq -e '.include | length == 1' <<<"$docker" >/dev/null
jq -e '.include[0].artifact_name == "ghcr.io/whengas/api"' <<<"$docker" >/dev/null
jq -e '.include[0].dependencies == ["whengas/api"]' <<<"$docker" >/dev/null

npm=$($root/scripts/resolve-artifact-renovate.sh "$tmpdir/artifacts.yaml" npm api)
jq -e '.include[0].artifact_type == "npm"' <<<"$npm" >/dev/null

missing=$($root/scripts/resolve-artifact-renovate.sh "$tmpdir/missing.yaml" docker api)
jq -e '.include == [{"configured":false}]' <<<"$missing" >/dev/null

unmatched=$($root/scripts/resolve-artifact-renovate.sh "$tmpdir/artifacts.yaml" pypi api)
jq -e '.include == [{"configured":false}]' <<<"$unmatched" >/dev/null

echo 'version: 1' > "$tmpdir/invalid.yaml"
if $root/scripts/resolve-artifact-renovate.sh "$tmpdir/invalid.yaml" docker api >/dev/null 2>&1; then
  echo "invalid catalog was accepted" >&2
  exit 1
fi

echo "test-artifact-renovate-config: ok"
