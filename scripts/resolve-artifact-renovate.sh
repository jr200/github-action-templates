#!/usr/bin/env bash
set -euo pipefail

config="${1:-.github/artifacts.yaml}"
publisher="${2:-}"
component="${3:-}"

[ -n "$publisher" ] || { echo "resolve-artifact-renovate: publisher is required" >&2; exit 2; }
[ -n "$component" ] || { echo "resolve-artifact-renovate: component is required" >&2; exit 2; }

# An absent catalog means the repository has not opted in. Emit a no-op
# matrix so reusable-workflow callers can stay identical in every repository.
if [ ! -f "$config" ]; then
  jq -nc '{include: [{configured: false}]}'
  exit 0
fi

for cmd in yq jq; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "resolve-artifact-renovate: $cmd is required" >&2
    exit 1
  }
done

catalog=$(yq -o=json -I=0 '.' "$config")
jq -e '
  (.version == 1) and
  (.artifacts | type == "array") and
  (all(.artifacts[];
    (.component | type == "string" and length > 0) and
    (.publisher | type == "string" and length > 0) and
    (.type | type == "string" and length > 0) and
    (.name | type == "string" and length > 0) and
    (.renovate.repository | type == "string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")) and
    (.renovate.dependencies | type == "array" and length > 0) and
    (all(.renovate.dependencies[]; type == "string" and length > 0))
  ))
' <<<"$catalog" >/dev/null || {
  echo "resolve-artifact-renovate: invalid $config" >&2
  exit 1
}

matches=$(jq -c \
  --arg publisher "$publisher" \
  --arg component "$component" '
    [.artifacts[]
      | select(.publisher == $publisher and .component == $component)
      | (.renovate.repository | split("/")) as $repository
      | {
          configured: true,
          artifact_type: .type,
          artifact_name: .name,
          target_repository: .renovate.repository,
          target_owner: $repository[0],
          target_name: $repository[1],
          dependencies: .renovate.dependencies
        }
    ]
  ' <<<"$catalog")

if [ "$(jq 'length' <<<"$matches")" -eq 0 ]; then
  jq -nc '{include: [{configured: false}]}'
else
  jq -c '{include: .}' <<<"$matches"
fi
