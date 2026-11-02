#!/usr/bin/env bash
# check.sh [file…]: compiles embedding-layer sources and touch-point files on this Mac exactly as
# the engine build does (its clang, flags, headers and generated headers), without building
# Chromium: compile errors in about a minute instead of a 30-minute iterate run. It doesn't link.
#   tools/check.sh                           what changed from origin/master: the layer's sources,
#                                            and the files of changed touch points
#   tools/check.sh browser_engine/be_tab.mm  just these (layer sources, or Chrome files a touch
#                                            point patches)
#   tools/check.sh all                       every layer source and touch-point file
# The headers come from the newest iterate run made with pack_headers (about 1 GB, unpacked once
# into ~/Library/Caches/browser-engine). Run one again when the dev base's Chromium changes.
set -euo pipefail
cd "$(dirname "$0")/.."
repo="MathiasWP/browser-engine"

run="${HEADERS_RUN:-}"
if [[ -z "$run" ]]; then
  for id in $(gh run list -R "$repo" --workflow iterate.yml --status success --limit 30 --json databaseId --jq '.[].databaseId'); do
    if gh api "repos/$repo/actions/runs/$id/artifacts" --jq '.artifacts[] | select(.name == "headers_x86_64" and (.expired | not)) | .name' | grep -q .; then
      run="$id"
      break
    fi
  done
fi
[[ -n "$run" ]] || { echo "No iterate run with headers; run one with pack_headers" >&2; exit 1; }
cache="$HOME/Library/Caches/browser-engine/headers-$run"
if [[ ! -f "$cache/compile_commands.json" ]]; then
  echo "Fetching the headers of run $run once…" >&2
  rm -rf "$cache.partial" && mkdir -p "$cache.partial/src"
  gh run download "$run" -R "$repo" -n headers_x86_64 -D "$cache.partial"
  zstd -d -c "$cache.partial/headers.tar.zst" | tar -C "$cache.partial/src" -xf -
  rm "$cache.partial/headers.tar.zst"
  rm -rf "$cache" && mv "$cache.partial" "$cache"
  # Older header sets go: each is about a gigabyte.
  find "$(dirname "$cache")" -maxdepth 1 -name 'headers-*' ! -path "$cache" -exec rm -rf {} +
fi
src="$cache/src"

# The layer as it is here, and the touch points as they are here, on the original files.
rsync -r -c --delete browser_engine/ "$src/browser_engine/"
(cd "$src/originals" && find . -type f) | while read -r f; do cp "$src/originals/$f" "$src/$f"; done
for patch in patches/browser_engine/*.patch; do
  patch -p1 -s -N -d "$src" -i "$PWD/$patch" >/dev/null || { echo "error: $(basename "$patch") doesn't apply" >&2; exit 1; }
done

files=("$@")
if [[ ${#files[@]} -eq 0 ]]; then
  files=($(git diff --name-only origin/master -- 'browser_engine/*.mm' 'browser_engine/*.cc'))
  for patch in $(git diff --name-only origin/master -- 'patches/browser_engine/*.patch'); do
    [[ -f "$patch" ]] && files+=($(sed -n 's|^+++ b/||p' "$patch"))
  done
elif [[ "${files[0]}" == all ]]; then
  files=($(ls browser_engine/*.mm browser_engine/*.cc) $(sed -n 's|^+++ b/||p' patches/browser_engine/*.patch | sort -u))
fi
[[ ${#files[@]} -gt 0 ]] || { echo "Nothing changed from origin/master"; exit 0; }

sdk="$(xcrun --sdk macosx --show-sdk-path)"
python3 - "$src" "$sdk" "${files[@]}" <<'EOF'
import json, os, shlex, subprocess, sys, time
src, sdk, files = sys.argv[1], sys.argv[2], sys.argv[3:]
commands = json.load(open(os.path.join(os.path.dirname(src), "compile_commands.json")))
by_file = {os.path.normpath(os.path.join("out/Default", c["file"])): c for c in commands}
failed = 0
for path in files:
    entry = by_file.get(os.path.normpath(path))
    if not entry:
        print(f"skip {path}: no compile command (a header, or a file the engine doesn't build)")
        continue
    args = shlex.split(entry["command"])
    out = []
    skip = False
    for i, arg in enumerate(args):
        if skip:
            skip = False
            continue
        if arg in ("-o", "-MF"):
            skip = True
            continue
        if arg in ("-MMD", "-c"):
            continue
        if arg == "-isysroot":
            out += [arg, sdk]
            skip = True
            continue
        out.append(arg)
    start = time.time()
    result = subprocess.run(out + ["-fsyntax-only"], cwd=os.path.join(src, "out/Default"))
    print(f"{'ok' if result.returncode == 0 else 'FAILED'} {path} ({time.time() - start:.0f} s)")
    failed += result.returncode != 0
sys.exit(1 if failed else 0)
EOF
