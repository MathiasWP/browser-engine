#!/bin/bash -eux

# Builds the embedding layer (//browser_engine) on top of a dev base and
# packages the engine. Run by .github/workflows/iterate.yml after the build
# state of a finished dev build (build.yml, flavor dev) has been unpacked into
# build/src by github_unpack_archive.sh, exactly as the resuming build jobs do.
#
#   github_iterate.sh build   [arch]   copy the layer in, apply its touch points,
#                                      check the base matches, run ninja
#   github_iterate.sh package [arch]   zip Chromium.app, the header and a manifest
#                                      into upload_engine/

set -o pipefail

_command="${1:?usage: github_iterate.sh build|package [arch]}"
_target_cpu="${2:-x86_64}"

_root_dir="$(dirname "$(greadlink -f "$0")")"
_src_dir="$_root_dir/build/src"
_out_dir="$_src_dir/out/Default"

# More edges than this means the base isn't the one our tree expects (another
# Chromium version, other flags, an unfinished chain): a rebuild of hours that
# a 6-hour job won't finish. The layer and its touch points are a few hundred.
_max_edges="${BE_MAX_EDGES:-5000}"

build() {
  if [[ ! -f "$_out_dir/args.gn" ]]; then
    echo "::error::No build state in $_src_dir; did github_unpack_archive.sh run?"
    exit 1
  fi
  local _flavor
  _flavor="$(cat "$_out_dir/build_flavor.txt" 2>/dev/null || echo release)"
  if [[ "$_flavor" != "dev" ]]; then
    echo "::error::The base is a '$_flavor' build; iterate needs a run of build.yml with flavor dev (a release base relinks with ThinLTO for over an hour)."
    exit 1
  fi
  if [[ ! -f "$_root_dir/build_finished_$_target_cpu.log" ]] && [[ ! -d "$_out_dir/Chromium.app" ]]; then
    echo "::warning::The base run may not have finished building; the edge count below will tell."
  fi

  # 1. The layer, as //browser_engine. --checksum: files whose content didn't
  #    change aren't rewritten, so they keep their mtimes and ninja doesn't
  #    rebuild them (matters once a base already contains the layer).
  #    Short options only: macOS ships openrsync, not GNU rsync.
  mkdir -p "$_src_dir/browser_engine"
  rsync -r -c -v --delete "$_root_dir/browser_engine/" "$_src_dir/browser_engine/"

  # 2. The touch points. build/src sits inside our own checkout, and `git apply`
  #    run from a subdirectory of a repository silently skips every file outside
  #    it ("Skipped patch"): stop git from finding the checkout. A patch the base
  #    already has (a base built with the layer) is left alone, so the files it
  #    touches keep their mtimes.
  export GIT_CEILING_DIRECTORIES="$_root_dir/build"
  cd "$_src_dir"
  local _patch
  for _patch in "$_root_dir"/patches/browser_engine/*.patch; do
    if git apply --reverse --check "$_patch" 2>/dev/null; then
      echo "Already applied: $(basename "$_patch")"
      continue
    fi
    if ! git apply --check "$_patch"; then
      echo "::error::$(basename "$_patch") doesn't apply to this base (Chromium $(cat "$_root_dir/ungoogled-chromium/chromium_version.txt")?)"
      exit 1
    fi
    git apply "$_patch"
    # Make sure it really changed the tree (see GIT_CEILING_DIRECTORIES above).
    git apply --reverse --check "$_patch"
    echo "Applied: $(basename "$_patch")"
  done

  # 3. Regenerate the ninja files now (chrome/BUILD.gn changed). A dry run
  #    would only "regenerate" and stop, and count one edge.
  ninja -C "$_out_dir" build.ninja

  # 4. Fail early if the base doesn't match.
  local _targets _edges
  _targets="$(cat "$_out_dir/build_targets.txt" 2>/dev/null || echo chrome)"
  _edges="$(ninja -C "$_out_dir" -n $_targets | grep -cE '^\[[0-9]+/[0-9]+\]' || true)"
  echo "ninja would run $_edges edges for: $_targets"
  if (( _edges > _max_edges )); then
    echo "::error::ninja would rebuild $_edges edges (more than $_max_edges): the base doesn't match this tree (Chromium version, args.gn, or an unfinished base run). Use a finished dev run of build.yml for this commit's ungoogled-chromium version."
    ninja -C "$_out_dir" -n -d explain $_targets 2>&1 | head -40 || true
    exit 1
  fi

  # 5. Build.
  echo "$(date +%s)" | tee "$_root_dir/iterate_build_start_$_target_cpu.log"
  ninja -C "$_out_dir" $_targets
  echo "$(date +%s)" | tee "$_root_dir/iterate_build_finished_$_target_cpu.log"
}

package() {
  local _app="$_out_dir/Chromium.app"
  local _framework="$_app/Contents/Frameworks/Chromium Framework.framework/Chromium Framework"
  local _upload="$_root_dir/upload_engine"
  if [[ ! -d "$_app" ]]; then
    echo "::error::No $_app; did the build step succeed?"
    exit 1
  fi
  # The one symbol the app looks up.
  if ! nm -gU "$_framework" | grep -q ' _BEEngineCreate$'; then
    echo "::error::The framework doesn't export _BEEngineCreate (chrome/app/framework.exports patch?)"
    exit 1
  fi

  rm -rf "$_upload"
  mkdir -p "$_upload"
  ditto -c -k --keepParent "$_app" "$_upload/Chromium.app.zip"
  cp "$_root_dir/browser_engine/public/BEEngine.h" "$_upload/BEEngine.h"

  local _chromium_version _api_version _git_sha
  _chromium_version="$(cat "$_root_dir/ungoogled-chromium/chromium_version.txt")"
  _api_version="$(sed -n 's/^#define BE_API_VERSION \([0-9][0-9]*\).*/\1/p' "$_root_dir/browser_engine/public/BEEngine.h")"
  _git_sha="${GITHUB_SHA:-$(git -C "$_root_dir" rev-parse HEAD)}"
  cat > "$_upload/engine.json" <<EOF
{
  "chromium_version": "$_chromium_version",
  "ungoogled_revision": "$(cat "$_root_dir/ungoogled-chromium/revision.txt")",
  "git_sha": "$_git_sha",
  "api_version": ${_api_version:-0},
  "arch": "$_target_cpu",
  "base_run_id": "${BE_BASE_RUN_ID:-}",
  "run_id": "${GITHUB_RUN_ID:-}"
}
EOF
  cat "$_upload/engine.json"
  ls -lah "$_upload"
}

case "$_command" in
  build) build ;;
  package) package ;;
  *)
    echo "usage: github_iterate.sh build|package [arch]"
    exit 2
    ;;
esac
