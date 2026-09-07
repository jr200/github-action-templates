#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/package-access.yaml" <<'EOF'
version: 1
packages:
  - owner: example
    owner_kind: organization
    package_type: container
    name: runtime
    repository: example/consumer
    required_access: read
    visibility: private
EOF

cat >"$tmp/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --write-out) shift 2 ;;
    *) shift ;;
  esac
done
if [[ -n "${MOCK_BODY:-}" ]]; then
  printf '%s\n' "$MOCK_BODY" >"$output"
else
  printf '%s\n' '{"visibility":"private"}' >"$output"
fi
printf '%s' "${MOCK_STATUS:-200}"
EOF
chmod +x "$tmp/curl"

run_check() {
  PATH="$tmp:$PATH" GH_TOKEN=test-token \
    "$root/scripts/check-package-access.sh" "$tmp/package-access.yaml" example/consumer
}

run_check | grep -q 'OK: example/consumer can read example/runtime'

if MOCK_STATUS=404 run_check >"$tmp/missing.out" 2>&1; then
  echo "missing package access unexpectedly passed" >&2
  exit 1
fi
grep -q "DRIFT: example/consumer's token cannot read example/runtime" "$tmp/missing.out"

if MOCK_BODY='{"visibility":"public"}' run_check >"$tmp/visibility.out" 2>&1; then
  echo "visibility drift unexpectedly passed" >&2
  exit 1
fi
grep -q 'DRIFT: example/runtime visibility is public; expected private' "$tmp/visibility.out"

wizard_output="$("$root/consumers/files/scripts/github-package-access-wizard" "$tmp/package-access.yaml")"
grep -Fq 'https://github.com/orgs/example/packages/container/runtime/settings' <<<"$wizard_output"
if grep -Fq '/container/package/runtime/settings' <<<"$wizard_output"; then
  echo "wizard generated the package landing route instead of the settings route" >&2
  exit 1
fi

echo 'package access checks passed'
