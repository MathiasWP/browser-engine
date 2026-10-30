#!/bin/bash
# Simple script for packing Ungoogled-Chromium macOS build artifacts on GitHub Actions

set -euo pipefail

_target_cpu="${1:-x86_64}"

_script_dir="$(dirname "$(greadlink -f "$0")")"
_root_dir="${GITHUB_WORKSPACE:-$(git -C "$_script_dir" rev-parse --show-toplevel)}"
_root_dir="$(greadlink -f "$_root_dir")"
_src_dir="$_root_dir/build/src"

# If build finished successfully
if [[ -f "$_root_dir/build_finished_$_target_cpu.log" ]] ; then
  # For packaging
  _chromium_version="$(cat "$_root_dir/ungoogled-chromium/chromium_version.txt")"
  _ungoogled_revision="$(cat "$_root_dir/ungoogled-chromium/revision.txt")"
  _package_revision="$(cat "$_root_dir/revision.txt")"

  _flavor="$(cat "$_src_dir/out/Default/build_flavor.txt" 2>/dev/null || echo release)"
  _flavor_suffix=""
  [[ "$_flavor" == "release" ]] || _flavor_suffix="-$_flavor"
  _file_name="ungoogled-chromium_${_chromium_version}-${_ungoogled_revision}.${_package_revision}_${_target_cpu}${_flavor_suffix}-macos.dmg"
  _hash_name="${_file_name}.hashes.md"

  cd "$_src_dir"

  if [[ -n "${MACOS_CERTIFICATE:-}" ]]; then
    # Prepare the certificate for app signing
    printf '%s' "$MACOS_CERTIFICATE" | base64 --decode > "$TMPDIR/certificate.p12"

    security create-keychain -p "$MACOS_CI_KEYCHAIN_PWD" build.keychain
    security default-keychain -s build.keychain
    security unlock-keychain -p "$MACOS_CI_KEYCHAIN_PWD" build.keychain
    security import "$TMPDIR/certificate.p12" -k build.keychain -P "$MACOS_CERTIFICATE_PWD" -T /usr/bin/codesign
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$MACOS_CI_KEYCHAIN_PWD" build.keychain
  else
    # No Developer ID certificate configured: sign ad hoc instead of failing.
    export MACOS_AD_HOC_SIGNING=1
  fi

  # Sign, notarize, staple, and package using the same path as local builds.
  "$_root_dir/sign_and_package_app.sh" "$_root_dir/$_file_name"

  cd "$_root_dir"
  echo -e "md5: \nsha1: \nsha256: " | tee ./hash_types.txt
  { md5sum "$_file_name" ; sha1sum "$_file_name" ; sha256sum "$_file_name" ; } | tee ./sums.txt

  _hash_md=$(paste ./hash_types.txt ./sums.txt | awk '{print $1 " " $2}')

  printf 'file_name=%s\n' "$_file_name" >> "$GITHUB_OUTPUT"

  printf '[Hashes](https://en.wikipedia.org/wiki/Cryptographic_hash_function) for the disk image `%s`: \n' "$_file_name" | tee -a ./${_hash_name}
  printf '\n```\n%s\n```\n' "$_hash_md" | tee -a ./${_hash_name}

  # Use separate folder for build product, so that it can be used as individual asset in case the release action fails
  mkdir -p release_asset
  mv -vn ./*.dmg release_asset/ || true

  ls -kahl release_asset/
  du -hs release_asset/
fi

gsync --file-system "$_src_dir"

# Needs to be compressed to stay below GitHub's upload limit 2 GB (?!) 2020-11-24; used to be  5-8GB (?)
# Level 3: packing at 11 took 14-31 min per job on the 4-core runners for about a fifth less size.
tar -C build -c -f - src | zstd -vv -3 -T0 -o build_src.tar.zst

sha256sum ./build_src.tar.zst | tee ./sums.txt

mkdir -p upload_part_build
mv -vn ./*.zst ./sums.txt upload_part_build/ || true
cp -va ./*.log upload_part_build/

ls -kahl upload_part_build/
du -hs upload_part_build/

mkdir upload_logs
mv -vn ./*.log upload_logs/

ls -kahl upload_logs/
du -hs upload_logs/

echo "ready for upload action"
