#!/usr/bin/env bash
set -euo pipefail

repository_directory=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
architecture=${1:-arm64}
case "$architecture" in
  arm64) artifact_arch=arm64 ;;
  x86_64) artifact_arch=x64 ;;
  *) echo 'Usage: bash scripts/release-local.sh [arm64|x86_64] [--dry-run]' >&2; exit 2 ;;
esac
if [[ $# -gt 2 || ( $# -eq 2 && $2 != --dry-run ) ]]; then
  echo 'Usage: bash scripts/release-local.sh [arm64|x86_64] [--dry-run]' >&2
  exit 2
fi
if [[ ${2:-} == --dry-run ]]; then
  printf 'Architecture: %s\nBuild → package (signature/DMG verification) → SHA-256\nNo tests, installation or publishing included.\n' "$architecture"
  exit 0
fi

# Both existing entry points must receive the same explicit architecture.
export DSH_BUILD_ARCHES="$architecture"
export DSH_BUILD_ARCH="$architecture"
bash "$repository_directory/scripts/build-app.sh"
bash "$repository_directory/scripts/package-dmg.sh"
app_version=$(sed -nE 's/^[[:space:]]*SWIFT_APP_VERSION[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "$repository_directory/Version.xcconfig" | head -n 1)
artifact="${SWIFT_DIST_DIR:-$repository_directory/dist}/DSH-Desktop-${app_version}-${artifact_arch}.dmg"
shasum -a 256 "$artifact"
