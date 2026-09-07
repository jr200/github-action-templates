#!/usr/bin/env bash
set -euo pipefail

config="${1:-.github/package-access.yaml}"
repository="${2:-${GITHUB_REPOSITORY:-}}"

for command in yq jq curl; do
  command -v "$command" >/dev/null || {
    echo "Required command is not installed: $command" >&2
    exit 2
  }
done

[[ -f "$config" ]] || { echo "Package access config not found: $config" >&2; exit 2; }

config_json="$(yq -o=json '.' "$config")"
if ! jq -e '
  .version == 1 and
  (.packages | type == "array" and length > 0) and
  all(.packages[];
    (.owner | type == "string" and length > 0) and
    (.owner_kind == "organization" or .owner_kind == "user") and
    (.package_type == "npm" or .package_type == "nuget" or
     .package_type == "container") and
    (.name | type == "string" and length > 0) and
    (.repository | test("^[^/]+/[^/]+$")) and
    .required_access == "read" and
    (.visibility == "private" or .visibility == "internal" or .visibility == "public")
  )
' >/dev/null <<<"$config_json"; then
  echo "Invalid package access config: $config" >&2
  exit 2
fi

if [[ -z "$repository" ]]; then
  repository="$(jq -r '.packages[0].repository' <<<"$config_json")"
fi

if ! jq -e --arg repository "$repository" 'all(.packages[]; .repository == $repository)' >/dev/null <<<"$config_json"; then
  echo "Every package entry must target the checked repository ($repository)" >&2
  exit 2
fi

token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
[[ -n "$token" ]] || {
  echo "Set GH_TOKEN or GITHUB_TOKEN. Run this check in GitHub Actions for an authoritative result." >&2
  exit 2
}

api_url="${GITHUB_API_URL:-https://api.github.com}"
failures=0
while IFS= read -r package; do
  owner="$(jq -r '.owner' <<<"$package")"
  owner_kind="$(jq -r '.owner_kind' <<<"$package")"
  package_type="$(jq -r '.package_type' <<<"$package")"
  package_name="$(jq -r '.name' <<<"$package")"
  expected_visibility="$(jq -r '.visibility' <<<"$package")"
  owner_path=orgs
  [[ "$owner_kind" == user ]] && owner_path=users
  encoded_name="$(jq -rn --arg value "$package_name" '$value | @uri')"
  response_file="$(mktemp)"

  set +e
  status="$(curl --silent --show-error --output "$response_file" --write-out '%{http_code}' \
    --header 'Accept: application/vnd.github+json' \
    --header "Authorization: Bearer ${token}" \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    "${api_url}/${owner_path}/${owner}/packages/${package_type}/${encoded_name}")"
  curl_status=$?
  set -e

  if [[ $curl_status -ne 0 ]]; then
    echo "ERROR: GitHub API request failed for ${owner}/${package_name}" >&2
    failures=$((failures + 1))
  elif [[ "$status" == 200 ]]; then
    actual_visibility="$(jq -r '.visibility // "unknown"' "$response_file")"
    if [[ "$actual_visibility" != "$expected_visibility" ]]; then
      echo "DRIFT: ${owner}/${package_name} visibility is ${actual_visibility}; expected ${expected_visibility}" >&2
      failures=$((failures + 1))
    else
      echo "OK: ${repository} can read ${owner}/${package_name}; visibility is ${actual_visibility}"
    fi
  elif [[ "$status" == 403 || "$status" == 404 ]]; then
    echo "DRIFT: ${repository}'s token cannot read ${owner}/${package_name} (HTTP ${status})" >&2
    failures=$((failures + 1))
  else
    message="$(jq -r '.message // "unknown GitHub API error"' "$response_file" 2>/dev/null || true)"
    echo "ERROR: GitHub API returned HTTP ${status} for ${owner}/${package_name}: ${message}" >&2
    failures=$((failures + 1))
  fi

  rm -f "$response_file"
done < <(jq -c '.packages[]' <<<"$config_json")

[[ $failures -eq 0 ]]
