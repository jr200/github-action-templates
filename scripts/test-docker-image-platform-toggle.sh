#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
caller="$ROOT/consumers/workflows/build-docker-image.yaml"
reusable="$ROOT/.github/workflows/build_docker_image_multiplatform.yaml"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

grep -q "DOCKER_IMAGE_PLATFORMS" "$caller"
grep -q "DOCKER_IMAGE_PLATFORMS" "$reusable"
grep -q "docker_image_platforms" "$reusable"
grep -q 'build-args: \${{ github.event.inputs.build-args' "$caller"
grep -Fq 'source-sha: ${{ fromJson(needs.configure.outputs.context).sha' "$caller"
grep -Fq 'context: ${{ matrix.context || '\''.'\'' }}' "$caller"
grep -q '\${{ inputs.build-args }}' "$reusable"
grep -q 'enable-gha-cache-export:' "$reusable"
grep -q 'cache-from: type=gha,scope=${{ inputs.image_name }}-${{ matrix.platform }}' "$reusable"
grep -q 'name: Publish image success tag' "$reusable"
grep -q 'docker buildx imagetools inspect' "$reusable"
grep -q 'success_tag="${image_name}-${IMAGE_TAG}"' "$reusable"
inspect_line=$(grep -n 'docker buildx imagetools inspect' "$reusable" | cut -d: -f1)
success_tag_line=$(grep -n 'name: Publish image success tag' "$reusable" | cut -d: -f1)
if [ "$success_tag_line" -le "$inspect_line" ]; then
    echo "image success tag must be published after manifest inspection" >&2
    exit 1
fi
grep -q "cache-to: \${{ inputs.enable-gha-cache-export && format('type=gha,scope={0}-{1},mode=min', inputs.image_name, matrix.platform) || '' }}" "$reusable"
if grep -q 'scope=${{ inputs.tag }}-' "$reusable"; then
    echo "docker image cache must survive release tags" >&2
    exit 1
fi

if grep -q "matrix filtering skipped" "$reusable"; then
    echo "docker image platform filtering must apply outside workflow_dispatch" >&2
    exit 1
fi

script="$TMPDIR/determine-platforms.sh"
yq -r '.jobs."setup-matrix".steps[] | select(.id == "create-matrix").run' "$reusable" \
    | sed \
        -e 's/^platforms=.*/platforms="${INPUT_PLATFORMS:-}"/' \
        -e 's/^docker_image_platforms=.*/docker_image_platforms="${DOCKER_IMAGE_PLATFORMS:-}"/' \
        -e 's/^default_universe=.*/default_universe="$DEFAULT_UNIVERSE"/' \
    > "$script"
chmod +x "$script"

export DEFAULT_UNIVERSE
DEFAULT_UNIVERSE=$(yq -r '.env.DEFAULT_UNIVERSE' "$reusable")

run_case() {
    local name="$1"
    local input_platforms="$2"
    local docker_image_platforms="$3"
    local expected_platforms="$4"
    local output="$TMPDIR/$name.out"

    GITHUB_OUTPUT="$output" \
        INPUT_PLATFORMS="$input_platforms" \
        DOCKER_IMAGE_PLATFORMS="$docker_image_platforms" \
        "$script" >/tmp/"$name".stdout

    local matrix
    matrix=$(grep '^matrix=' "$output" | sed 's/^matrix=//')
    jq -e --argjson expected "$expected_platforms" '
      map(.platform) == $expected
    ' <<<"$matrix" >/dev/null
}

run_case default "" "" '["linux/amd64","linux/arm64"]'
run_case org_csv "" "linux/amd64" '["linux/amd64"]'
run_case org_json "" '["linux/arm64"]' '["linux/arm64"]'
run_case input_overrides_org '["linux/amd64","linux/arm64"]' "linux/amd64" '["linux/amd64","linux/arm64"]'

if GITHUB_OUTPUT="$TMPDIR/invalid.out" \
    INPUT_PLATFORMS="" \
    DOCKER_IMAGE_PLATFORMS="linux/s390x" \
    "$script" >/tmp/invalid-platform.stdout 2>/tmp/invalid-platform.stderr; then
    echo "expected unsupported platform to fail" >&2
    exit 1
fi
grep -q "unsupported docker image platform" /tmp/invalid-platform.stdout
