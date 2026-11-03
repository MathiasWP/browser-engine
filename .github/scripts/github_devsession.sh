#!/bin/bash -eu

# The loop of devsession.yml: on a runner that has unpacked a dev base once, builds each new commit
# of the branch as github_iterate.sh does and publishes the engine to the release "dev-session":
#   engine-<sha>.zip   Chromium.app.zip, BEEngine.h and engine.json, as iterate's engine_x86_64
#   engine-<sha>.log   instead, when the build failed: the end of its log
# Only what changed since the previous build is rebuilt. Stops after $BE_IDLE_MINUTES without a new
# commit, or before the job's 6-hour limit.

set -o pipefail

_root_dir="$(dirname "$(greadlink -f "$0")")"
_src_dir="$_root_dir/build/src"
_branch="${BE_BRANCH:?}"
_release="dev-session"
_idle="${BE_IDLE_MINUTES:-45}"
_deadline=$(( $(date +%s) + 5 * 3600 + 30 * 60 ))
_last_change=$(date +%s)
_built=""
# The touch points as last applied, to take back the ones that change or go: at first, the dev
# base's own (those of the commit its run built).
_applied="$_root_dir/build/applied_patches"
mkdir -p "$_applied"

gh release view "$_release" >/dev/null 2>&1 ||
  gh release create "$_release" --prerelease --title "Dev session engines" \
    --notes "Engines built by devsession.yml, one per commit; for scripts/fetch-engine.sh in the app."

cd "$_root_dir"
_base_sha="$(gh run view "${BE_BASE_RUN_ID:?}" -R "$GITHUB_REPOSITORY" --json headSha --jq .headSha)"
git fetch -q --depth=1 origin "$_base_sha"
for _patch in $(git ls-tree --name-only "$_base_sha" patches/browser_engine/ | grep '\.patch$'); do
  git show "$_base_sha:$_patch" >"$_applied/$(basename "$_patch")"
done
while (( $(date +%s) < _deadline )); do
  git fetch -q origin "$_branch" || { sleep 20; continue; }
  _sha="$(git rev-parse FETCH_HEAD)"
  if [[ "$_sha" == "$_built" ]]; then
    (( $(date +%s) - _last_change > _idle * 60 )) && { echo "Idle for $_idle minutes; ending the session."; break; }
    sleep 20
    continue
  fi
  _last_change=$(date +%s)
  echo "::group::Build ${_sha:0:12}"
  # This commit's layer, touch points and scripts, files it deleted included.
  rm -rf browser_engine patches/browser_engine
  git checkout -q --force "$_sha" -- browser_engine patches .github/scripts
  cp -a .github/scripts/. ./
  export GITHUB_SHA="$_sha"

  # Touch points that changed or went since the last build come out first; github_iterate.sh
  # then applies what isn't applied, leaving unchanged ones (and their files' mtimes) alone.
  export GIT_CEILING_DIRECTORIES="$_root_dir/build"
  for _old in "$_applied"/*.patch; do
    [[ -e "$_old" ]] || continue
    if ! cmp -s "$_old" "patches/browser_engine/$(basename "$_old")"; then
      (cd "$_src_dir" && git apply --reverse "$_old") && rm "$_old"
    fi
  done

  _log="$_root_dir/devsession_${_sha:0:12}.log"
  if ./github_iterate.sh build x86_64 >"$_log" 2>&1 && ./github_iterate.sh package x86_64 >>"$_log" 2>&1; then
    cp patches/browser_engine/*.patch "$_applied/"
    (cd upload_engine && zip -q -0 "../engine-$_sha.zip" Chromium.app.zip BEEngine.h engine.json)
    gh release upload "$_release" "engine-$_sha.zip" --clobber
    rm "engine-$_sha.zip"
    echo "Published engine-$_sha.zip"
  else
    tail -150 "$_log" >"engine-$_sha.log"
    gh release upload "$_release" "engine-$_sha.log" --clobber
    rm "engine-$_sha.log"
    echo "::error::The build of $_sha failed; its log is engine-$_sha.log"
  fi
  # Keep the release small: the ten newest engines.
  gh release view "$_release" --json assets --jq '.assets | sort_by(.createdAt) | reverse | .[10:] | .[].name' |
    while read -r _name; do gh release delete-asset "$_release" "$_name" --yes; done
  _built="$_sha"
  echo "::endgroup::"
done
