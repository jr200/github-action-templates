#!/usr/bin/env bash
# Fail PRs that downgrade Renovate-tracked Dockerfile ARG pins.
#
# Scope (v1): Dockerfile `ARG *_VERSION=...` lines immediately preceded by a
# `# renovate:` annotation, matching the shared customManager in default.json.
#
# Policy:
# - Upgrades are allowed
# - Same-version rewrites are allowed
# - Downgrades fail CI by default
# - Explicit override is allowed only when the PR carries either:
#     * label: allow-version-downgrade
#     * PR body marker: allow-version-downgrade: true
#       or [allow-version-downgrade]
#
# Usage:
#   lint-version-downgrades.sh <base-ref>

set -euo pipefail

base_ref="${1:-}"

if [[ -z "$base_ref" ]]; then
  echo "lint-version-downgrades: no base ref provided; skipping" >&2
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required" >&2
  exit 2
fi

git fetch --quiet --no-tags origin "$base_ref"

if [[ -n "${GITHUB_EVENT_PATH:-}" ]] && [[ -f "${GITHUB_EVENT_PATH}" ]] && command -v jq >/dev/null 2>&1; then
  if jq -e '
      (.pull_request.labels // [] | any(.name == "allow-version-downgrade"))
      or ((.pull_request.body // "") | test("(^|\\n)allow-version-downgrade:\\s*true(\\n|$)|\\[allow-version-downgrade\\]"; "i"))
    ' "$GITHUB_EVENT_PATH" >/dev/null; then
    echo "lint-version-downgrades: explicit allow-version-downgrade override present; skipping" >&2
    exit 0
  fi
fi

python3 - "$base_ref" <<'PY'
from __future__ import annotations

import pathlib
import re
import subprocess
import sys

BASE_REF = sys.argv[1]

ANNOTATION_RE = re.compile(r"^\s*#\s*renovate:\s+(?P<meta>.+?)\s*$")
DEP_RE = re.compile(r"(?:^|\s)depName=(?P<dep>\S+)")
ARG_RE = re.compile(r"^\s*ARG\s+(?P<arg>[A-Z0-9_]+_VERSION)=(?P<value>\S+)\s*$")
SEMVER_RE = re.compile(r"(?:^|.*/)?v?(?P<major>\d+)\.(?P<minor>\d+)\.(?P<patch>\d+)$")


def git(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", *args], check=check, text=True, capture_output=True)


def changed_dockerfiles() -> list[str]:
    diff = git("diff", "--name-only", f"origin/{BASE_REF}...HEAD").stdout.splitlines()
    return [
        path
        for path in diff
        if pathlib.PurePosixPath(path).name == "Dockerfile" or "/Dockerfile." in path or path.endswith("Dockerfile")
    ]


def parse_entries(text: str) -> dict[tuple[str, str], tuple[str, str]]:
    lines = text.splitlines()
    out: dict[tuple[str, str], tuple[str, str]] = {}
    for idx in range(len(lines) - 1):
        match_anno = ANNOTATION_RE.match(lines[idx])
        if not match_anno:
            continue
        match_dep = DEP_RE.search(match_anno.group("meta"))
        if not match_dep:
            continue
        match_arg = ARG_RE.match(lines[idx + 1])
        if not match_arg:
            continue
        dep = match_dep.group("dep")
        arg = match_arg.group("arg")
        value = match_arg.group("value")
        out[(dep, arg)] = (value, str(idx + 2))
    return out


def load_base_file(path: str) -> str | None:
    result = git("show", f"origin/{BASE_REF}:{path}", check=False)
    if result.returncode != 0:
        return None
    return result.stdout


def normalize(value: str) -> tuple[int, int, int] | None:
    match = SEMVER_RE.match(value)
    if not match:
        return None
    return tuple(int(match.group(part)) for part in ("major", "minor", "patch"))


def main() -> int:
    files = changed_dockerfiles()
    if not files:
        print("lint-version-downgrades: no changed Dockerfiles; skipping", file=sys.stderr)
        return 0

    failures: list[str] = []
    checked = 0

    for path in files:
        head_path = pathlib.Path(path)
        if not head_path.exists():
            continue
        base_text = load_base_file(path)
        if base_text is None:
            continue
        head_entries = parse_entries(head_path.read_text())
        base_entries = parse_entries(base_text)

        for key, (head_value, head_line) in head_entries.items():
            if key not in base_entries:
                continue
            dep, arg = key
            base_value, _base_line = base_entries[key]
            if head_value == base_value:
                checked += 1
                continue
            head_norm = normalize(head_value)
            base_norm = normalize(base_value)
            if head_norm is None or base_norm is None:
                failures.append(
                    f"{path}:{head_line} {dep} ({arg}) changed {base_value} -> {head_value}, but one side is not a comparable semver pin"
                )
                continue
            checked += 1
            if head_norm < base_norm:
                failures.append(
                    f"{path}:{head_line} {dep} ({arg}) downgraded {base_value} -> {head_value}"
                )

    print(f"lint-version-downgrades: checked={checked} files={len(files)} failures={len(failures)}", file=sys.stderr)
    if failures:
        print("Blocked version downgrades detected:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    return 0


raise SystemExit(main())
PY
