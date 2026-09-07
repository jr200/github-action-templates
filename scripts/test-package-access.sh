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

cat >"$tmp/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  "auth status") exit 0 ;;
  "workflow run")
    for argument in "$@"; do
      case "$argument" in request_id=*) printf '%s\n' "${argument#request_id=}" >"$MOCK_GH_STATE" ;; esac
    done
    ;;
  "run list")
    request_id="$(cat "$MOCK_GH_STATE")"
    printf '%s\n' '[{"databaseId":123,"displayTitle":"package-access-drift ('"${request_id}"')","url":"https://github.example/run/123"}]'
    ;;
  "run watch")
    [[ "${MOCK_WIZARD_CONCLUSION:-success}" == success ]]
    ;;
  "run view")
    if [[ " $* " == *" --log-failed "* ]]; then
      echo "${MOCK_WIZARD_LOG:-DRIFT: example/consumer token cannot read example/runtime}"
    else
      printf '%s\n' "${MOCK_WIZARD_CONCLUSION:-success}"
    fi
    ;;
  *) echo "unexpected gh invocation: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$tmp/gh"

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

wizard_output="$(
  export MOCK_GH_STATE="$tmp/gh-state"
  export MOCK_WIZARD_CONCLUSION=success
  export PATH="$tmp:$PATH"
  "$root/consumers/files/scripts/github-package-access-wizard" "$tmp/package-access.yaml"
)"
grep -Fq 'Package access is in sync. No changes are needed.' <<<"$wizard_output"
if grep -Fq 'Required Actions access:' <<<"$wizard_output"; then
  echo "wizard printed repair instructions for synchronized access" >&2
  exit 1
fi

if wizard_output="$(
  export MOCK_GH_STATE="$tmp/gh-state"
  export MOCK_WIZARD_CONCLUSION=failure
  export PATH="$tmp:$PATH"
  "$root/consumers/files/scripts/github-package-access-wizard" "$tmp/package-access.yaml"
)"; then
  echo "wizard unexpectedly passed when the repository token lacked access" >&2
  exit 1
fi
grep -Fq 'Package access drift detected' <<<"$wizard_output"
grep -Fq 'https://github.com/orgs/example/packages/container/runtime/settings' <<<"$wizard_output"
if grep -Fq '/container/package/runtime/settings' <<<"$wizard_output"; then
  echo "wizard generated the package landing route instead of the settings route" >&2
  exit 1
fi

set +e
wizard_output="$(
  export MOCK_GH_STATE="$tmp/gh-state"
  export MOCK_WIZARD_CONCLUSION=failure
  export MOCK_WIZARD_LOG='runner provisioning failed'
  export PATH="$tmp:$PATH"
  "$root/consumers/files/scripts/github-package-access-wizard" "$tmp/package-access.yaml" 2>&1
)"
wizard_status=$?
set -e
if [[ "$wizard_status" -ne 2 ]]; then
  echo "wizard treated an infrastructure failure as package access drift" >&2
  exit 1
fi
grep -Fq 'workflow failed before reporting drift' <<<"$wizard_output"
if grep -Fq 'Required Actions access:' <<<"$wizard_output"; then
  echo "wizard printed repair instructions for an infrastructure failure" >&2
  exit 1
fi

echo 'package access checks passed'
