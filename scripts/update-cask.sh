#!/bin/sh
# Writes the Homebrew cask for a release to stdout.
# Usage: scripts/update-cask.sh VERSION SHA256   (VERSION without the "v", e.g. 0.2.0)
set -eu
VERSION=$1; SHA256=$2
sed -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$SHA256/" "$(dirname "$0")/../packaging/homebrew/tomtomsync.rb.in"
