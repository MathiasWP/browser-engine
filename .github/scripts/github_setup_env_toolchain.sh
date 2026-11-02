#!/bin/bash -eux

# Simple script for setting up all toolchain dependencies for building Ungoogled-Chromium on macOS

brew install go ninja coreutils --overwrite

# Install PySocks and httplib2 for Python from PyPI
pip3 install PySocks httplib2 --break-system-packages

# Install ESBuild and TypeScript from Homebrew
brew install esbuild typescript

# The build and its patches expect Homebrew's Apple silicon prefix; on Intel it's /usr/local.
if [[ "$(brew --prefix)" != "/opt/homebrew" ]]; then
  sudo mkdir -p /opt/homebrew/bin
  sudo ln -sf "$(brew --prefix)/bin/esbuild" "$(brew --prefix)/bin/tsc" /opt/homebrew/bin/
fi

# Freshly installed, the tools would be newer than everything a resumed build made with them, and
# ninja would redo all of DevTools' TypeScript bundling: date them back.
touch -t 202001010000 "$(greadlink -f "$(brew --prefix)/bin/esbuild")" "$(greadlink -f "$(brew --prefix)/bin/tsc")"
