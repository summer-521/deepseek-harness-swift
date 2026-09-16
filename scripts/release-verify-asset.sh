#!/usr/bin/env bash
# Fetch a release asset back from GitHub and prove it is the file the feed
# describes: same length, and — for a local artifact — same SHA-256.
#
# The appcast is only pushed after this passes, so a truncated upload must stop
# the release instead of being advertised to every installed copy. It is a
# separate script so the prepare-only flow can hand the operator the exact
# command, and so the check can be re-run later against a published release.
#
# `--feed` is the same check for a release that is already public: the local
# artifact is gone by then, so the downloaded bytes are compared with the length
# the served feed advertises for them. A mismatch means every client is being
# handed a download Sparkle will refuse.
#
# Usage: bash scripts/release-verify-asset.sh <tag> <dmg path> <sha256>
#        bash scripts/release-verify-asset.sh --feed <tag> <asset url> <length>
set -euo pipefail

usage() {
	printf '%s\n' \
		'Usage: bash scripts/release-verify-asset.sh <tag> <dmg path> <sha256>' \
		'       bash scripts/release-verify-asset.sh --feed <tag> <asset url> <length>' >&2
}

mode=local
if [[ "${1:-}" == "--feed" ]]; then
	mode=feed
	shift
fi
if [[ $# -ne 3 ]]; then
	usage
	exit 2
fi

tag="$1"
subject="$2"
expected="$3"

fail() { echo "release-verify-asset: $1" >&2; exit 1; }

command -v gh >/dev/null || fail "gh is required"
[[ -n "$tag" ]] || fail "a release tag is required"

work_directory="$(mktemp -d "${TMPDIR:-/tmp}/dsh-release-verify.XXXXXX")"
cleanup() { rm -rf "$work_directory"; }
trap cleanup EXIT

if [[ "$mode" == "feed" ]]; then
	[[ "$expected" =~ ^[1-9][0-9]*$ ]] \
		|| fail "the length the feed advertises must be a positive whole number, got: $expected"
	# The enclosure URL is what the feed points at; it also names the asset.
	name="$(basename "${subject%%\?*}")"
	[[ -n "$name" && "$name" != "/" ]] || fail "the feed url names no asset: $subject"
	gh release download "$tag" --pattern "$name" --dir "$work_directory" --clobber
	downloaded="$work_directory/$name"
	[[ -f "$downloaded" ]] || fail "GitHub release $tag does not carry $name"
	published_size="$(stat -f%z "$downloaded")"
	[[ "$published_size" == "$expected" ]] \
		|| fail "the published $name is $published_size bytes but the feed advertises $expected"
	echo "verified published asset: $name ($published_size bytes, matches the feed)"
	exit 0
fi

local_dmg="$subject"
expected_digest="$expected"
[[ -f "$local_dmg" ]] || fail "the local artifact does not exist: $local_dmg"
[[ "$expected_digest" =~ ^[0-9a-f]{64}$ ]] || fail "the expected digest must be a lowercase SHA-256: $expected_digest"

name="$(basename "$local_dmg")"
gh release download "$tag" --pattern "$name" --dir "$work_directory" --clobber
downloaded="$work_directory/$name"
[[ -f "$downloaded" ]] || fail "GitHub release $tag does not carry $name"

local_size="$(stat -f%z "$local_dmg")"
uploaded_size="$(stat -f%z "$downloaded")"
[[ "$uploaded_size" == "$local_size" ]] \
	|| fail "uploaded $name is $uploaded_size bytes, expected $local_size"

uploaded_digest="$(shasum -a 256 "$downloaded" | awk '{print $1}')"
[[ "$uploaded_digest" == "$expected_digest" ]] \
	|| fail "uploaded $name hashes to $uploaded_digest, expected $expected_digest"

echo "verified uploaded asset: $name ($uploaded_size bytes, sha256 $uploaded_digest)"
