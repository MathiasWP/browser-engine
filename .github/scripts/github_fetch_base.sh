#!/bin/bash -eux

# Streams a dev base's build state into build/src for iterate.yml: the artifact's zip holds
# build_src.tar.zst stored (compression-level 0), so download, decompression and extraction run
# at once and the 8 GB archive never lands on disk. The zip's CRC checks the data.
#   BE_BASE_RUN_ID  the build.yml (or iterate.yml) run whose github_build_artifact_x86_64 it is
#   GH_TOKEN        a token that can read the repository's actions

set -o pipefail

_root_dir="$(dirname "$(greadlink -f "$0")")"
_repo="${GITHUB_REPOSITORY:-MathiasWP/browser-engine}"

_artifact_id="$(gh api "repos/$_repo/actions/runs/$BE_BASE_RUN_ID/artifacts" \
  --jq '.artifacts[] | select(.name == "github_build_artifact_x86_64" and (.expired | not)) | .id')"
if [[ -z "$_artifact_id" ]]; then
  echo "::error::Run $BE_BASE_RUN_ID has no github_build_artifact_x86_64 (expired, or not a dev base)"
  exit 1
fi

# The API answers with a redirect to the storage; fetch that without our token.
_url="$(curl -sS -o /dev/null -w '%{redirect_url}' -H "Authorization: Bearer $GH_TOKEN" \
  "https://api.github.com/repos/$_repo/actions/artifacts/$_artifact_id/zip")"

mkdir -p "$_root_dir/build"
curl -sSf --retry 3 "$_url" | bsdtar -xOf - build_src.tar.zst | tar -C "$_root_dir/build" -xf -

df -h "$_root_dir"
