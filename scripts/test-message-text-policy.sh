#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

policy="$ROOT/shared/.githooks/lint-message-text.sh"

good="$TMPDIR/good-message"
bad="$TMPDIR/bad-message"
custom="$TMPDIR/custom-message"

printf '%s\n' "fix: update shared workflow sync" > "$good"
"$policy" "commit message" "$good"

printf '%s\n' "fix: update generated text from codex" > "$bad"
if "$policy" "commit message" "$bad" >/tmp/message-policy.out 2>/tmp/message-policy.err; then
    echo "expected default blocked term to fail" >&2
    exit 1
fi
grep -q "blocked attribution term" /tmp/message-policy.err

printf '%s\n' "fix: update forbidden marker" > "$custom"
if BANNED_COMMIT_WORDS=forbidden "$policy" "commit message" "$custom" >/tmp/message-policy-custom.out 2>/tmp/message-policy-custom.err; then
    echo "expected custom blocked term to fail" >&2
    exit 1
fi
grep -q "blocked attribution term" /tmp/message-policy-custom.err
