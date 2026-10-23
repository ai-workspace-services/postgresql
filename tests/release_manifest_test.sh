#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/release-manifest-test.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT

runner_temp="$test_tmp/runner"
fixture_dir="$test_tmp/fixture"
mkdir -p "$runner_temp" "$fixture_dir"
printf 'chart package fixture\n' > "$fixture_dir/postgresql-fixture.tgz"
printf 'release archive fixture\n' > "$fixture_dir/postgresql-fixture.tar.gz"

env -u GITHUB_REF_TYPE \
  RUNNER_TEMP="$runner_temp" \
  RELEASE_INPUT_DIRS="$fixture_dir" \
  RELEASE_TAG='daily-build-regression-r1' \
  GITHUB_REPOSITORY='example/postgresql' \
  GITHUB_SHA='0123456789abcdef0123456789abcdef01234567' \
  IMAGE_REFS=$'ghcr.io/example/stunnel-server:test\nghcr.io/example/stunnel-client:test\nghcr.io/example/postgresql:test' \
  CHART_REFS='oci://ghcr.io/example/charts/postgresql' \
  bash "$repo_root/.github/scripts/publish-release-artifacts.sh" >/dev/null

manifest="$runner_temp/release-assets/release-manifest.json"
jq -e '
  .repository == "example/postgresql" and
  .commit == "0123456789abcdef0123456789abcdef01234567" and
  .tag == "daily-build-regression-r1" and
  .image_refs == [
    "ghcr.io/example/stunnel-server:test",
    "ghcr.io/example/stunnel-client:test",
    "ghcr.io/example/postgresql:test"
  ] and
  .chart_refs == ["oci://ghcr.io/example/charts/postgresql"] and
  (.files | sort) == ["postgresql-fixture.tar.gz", "postgresql-fixture.tgz"]
' "$manifest" >/dev/null

echo 'release manifest newline-array regression passed'
