#!/usr/bin/env bash
set -euo pipefail

release_tag="${RELEASE_TAG:-${GITHUB_REF_NAME:-snapshot}}"
assets_dir="${RUNNER_TEMP}/release-assets"
mkdir -p "${assets_dir}"

if [[ -n "${RELEASE_BUILD_COMMAND:-}" ]]; then
  bash -c "${RELEASE_BUILD_COMMAND}"
fi

copy_release_files() {
  local dir
  IFS=':' read -r -a dirs <<< "${RELEASE_INPUT_DIRS:-dist:build:bin:release}"
  for dir in "${dirs[@]}"; do
    [[ -d "${dir}" ]] || continue
    while IFS= read -r -d '' file; do
      cp "${file}" "${assets_dir}/$(basename "${file}")"
    done < <(find "${dir}" -type f \( -name '*.bin' -o -name '*.zip' -o -name '*.tgz' -o -name '*.tar.gz' -o -name '*.tar.zst' \) -print0)
  done
}

copy_release_files

if [[ -n "${CHART_DIR:-}" ]]; then
  helm package "${CHART_DIR}" --version "${CHART_VERSION}" --destination "${assets_dir}" >/dev/null
fi

files_json="$(find "${assets_dir}" -maxdepth 1 -type f -print | sed 's#^.*/##' | jq -Rsc 'split("\\n") | map(select(length > 0))')"
jq -n \
  --arg repository "${GITHUB_REPOSITORY}" \
  --arg commit "${GITHUB_SHA}" \
  --arg tag "${release_tag}" \
  --arg image_refs "${IMAGE_REFS:-}" \
  --arg chart_refs "${CHART_REFS:-}" \
  --argjson files "${files_json}" \
  '{schema: 1, repository: $repository, commit: $commit, tag: $tag, image_refs: ($image_refs | split("\\n") | map(select(length > 0))), chart_refs: ($chart_refs | split("\\n") | map(select(length > 0))), files: $files}' \
  > "${assets_dir}/release-manifest.json"

printf '%s\n' "${assets_dir}"

if [[ "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
  # With immutable releases enabled, assets cannot be added once a release is
  # published (HTTP 422), and `gh release create` publishes immediately. Build
  # the release as a draft, attach every asset, and publish last. `gh release
  # view` does not see drafts, so look the tag up through `gh release list`.
  release_state="$(gh release list --limit 100 --json tagName,isDraft \
    | jq -r --arg tag "${release_tag}" \
      '[.[] | select(.tagName == $tag)] | if length == 0 then "none" else (.[0].isDraft | tostring) end')"

  if [[ "${release_state}" == "none" ]]; then
    gh release create "${release_tag}" --draft --title "${GITHUB_REPOSITORY} ${release_tag}" --notes "Automated CI release for ${GITHUB_SHA}."
    release_state=true
  fi

  if [[ "${release_state}" == "true" ]]; then
    gh release upload "${release_tag}" "${assets_dir}"/* --clobber
    gh release edit "${release_tag}" --draft=false
  elif ! gh release upload "${release_tag}" "${assets_dir}"/* --clobber; then
    # A re-run found the release already published. An immutable release keeps
    # the assets from the first run, so only fail when one of them is missing.
    wanted_assets="$(find "${assets_dir}" -maxdepth 1 -type f -print | sed 's#^.*/##' | jq -Rsc 'split("\n") | map(select(length > 0))')"
    published_assets="$(gh release view "${release_tag}" --json assets --jq '[.assets[].name]')"
    missing_assets="$(jq -nc --argjson wanted "${wanted_assets}" --argjson published "${published_assets}" '$wanted - $published')"
    [[ "${missing_assets}" == "[]" ]] || {
      echo "::error::Release ${release_tag} is already published and is missing assets: ${missing_assets}" >&2
      exit 1
    }
    echo "Release ${release_tag} is already published with all assets; nothing to upload."
  fi
fi
