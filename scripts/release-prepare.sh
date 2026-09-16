#!/usr/bin/env bash
# Prepare one Swift shell release, and optionally publish it.
#
# The checklist this replaces was ten hand-run steps with two easy-to-miss
# invariants: the appcast must carry the length and signature of the exact DMG
# bytes that get uploaded, and the artifact must exist before the feed that
# points at it is written. The steps are:
#
#   npm test → bump Version.xcconfig + README → build + DMG → sign → appcast →
#   release commit → annotated tag → push main + tag → gh release create
#
# Without --publish the script stops after the appcast and prints the remaining
# commands, so a release can be prepared, inspected and finished by hand.
#
# Usage: bash scripts/release-prepare.sh <version> <build> --notes <file>
#          [--publish] [--skip-tests] [--dry-run]
set -euo pipefail

repository_directory="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$repository_directory"

sparkle_account="${DSH_SPARKLE_ACCOUNT:-dsh-swift}"
dist_directory="${SWIFT_DIST_DIR:-$repository_directory/dist}"
notes_file=""
publish=false
run_tests=true
dry_run=false

usage() {
	printf '%s\n' \
		'Usage: bash scripts/release-prepare.sh <version> <build> --notes <file>' \
		'         [--publish] [--skip-tests] [--dry-run]' >&2
}

if [[ $# -lt 1 ]]; then
	usage
	exit 2
fi
version="$1"; shift
if [[ $# -lt 1 ]]; then
	usage
	exit 2
fi
build="$1"; shift

while [[ $# -gt 0 ]]; do
	case "$1" in
		--notes) notes_file="${2:-}"; shift 2 ;;
		--publish) publish=true; shift ;;
		--skip-tests) run_tests=false; shift ;;
		--dry-run) dry_run=true; shift ;;
		*) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
	esac
done

fail() { echo "release-prepare: $1" >&2; exit 1; }
step() { printf '\n=== %s ===\n' "$1"; }

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must look like 1.2.6, got: $version"
[[ "$build" =~ ^[0-9]+$ ]] || fail "build must be a whole number, got: $build"
[[ -n "$notes_file" && -s "$notes_file" ]] || fail "--notes must name a non-empty release-notes file"
[[ "$(uname -m)" == arm64 ]] || fail "releases are built on Apple Silicon only"
command -v node >/dev/null || fail "node is required"
command -v gh >/dev/null || fail "gh is required for --publish"

tag="v$version"
dmg="$dist_directory/DSH-Desktop-$version-arm64.dmg"

step "Preflight"
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || fail "the working tree has uncommitted tracked changes"
[[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || fail "releases are cut from main"
git fetch --quiet origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main is not up to date with origin/main"
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
	fail "tag $tag already exists"
fi
if git ls-remote --exit-code --tags origin "$tag" >/dev/null 2>&1; then
	fail "tag $tag already exists on origin"
fi
echo "releasing $version (build $build) as $tag"

if $dry_run; then
	printf '%s\n' \
		"Plan for $tag:" \
		"  1. bump Version.xcconfig and the three README references" \
		"  2. npm test$($run_tests || echo ' (skipped)')" \
		"  3. bash scripts/release-local.sh arm64 → $dmg" \
		"  4. sign the DMG with Sparkle account $sparkle_account" \
		"  5. write the newest appcast item with that length and signature" \
		"  6. release commit, annotated tag, push, gh release create$($publish || echo ' (prepare only; pass --publish to continue)')"
	exit 0
fi

step "Bump release metadata"
node "$repository_directory/scripts/release-metadata.mjs" bump --version "$version" --build "$build" --write
node "$repository_directory/scripts/release-metadata.mjs" show

if $run_tests; then
	step "Test the release commit's content"
	npm test
fi

step "Build and package"
bash "$repository_directory/scripts/release-local.sh" arm64
[[ -f "$dmg" ]] || fail "the packager did not produce $dmg"

# `build-app.sh` clears `.build/xcode/<arch>` at the start of every run and
# checks Sparkle out again, so the signing tool is located after the build.
sign_update=""
while IFS= read -r candidate; do
	sign_update="$candidate"
	break
done < <(find "$repository_directory/.build" -maxdepth 8 -name sign_update -path '*sparkle*' -not -path '*old_dsa_scripts*' 2>/dev/null | head -n 1)
[[ -n "$sign_update" ]] || fail "Sparkle's sign_update was not found under .build; build Sparkle first or install the Sparkle tools"

length="$(stat -f%z "$dmg")"
digest="$(shasum -a 256 "$dmg" | awk '{print $1}')"
echo "artifact: $dmg"
echo "length:   $length"
echo "sha256:   $digest"

step "Sign with Sparkle ($sparkle_account)"
signature_output="$("$sign_update" --account "$sparkle_account" "$dmg")"
printf '%s\n' "$signature_output"
signature="$(printf '%s' "$signature_output" | sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p' | head -n 1)"
[[ -n "$signature" ]] || fail "sign_update did not print an edSignature"
signed_length="$(printf '%s' "$signature_output" | sed -nE 's/.*(sparkle:)?length="([0-9]+)".*/\2/p' | head -n 1)"
if [[ -n "$signed_length" && "$signed_length" != "$length" ]]; then
	fail "sign_update reports length $signed_length but the DMG is $length bytes; the feed would describe different bytes"
fi

step "Write the appcast item"
node "$repository_directory/scripts/release-metadata.mjs" appcast \
	--version "$version" --build "$build" \
	--length "$length" --signature "$signature" \
	--notes-file "$notes_file" --write
node --test "$repository_directory/test/swift-release-consistency.test.js"

if ! $publish; then
	step "Prepared, not published"
	cat <<EOF
Next steps (or re-run with --publish):
  git add Version.xcconfig README.md appcast-swift.xml
  git commit -m "release: prepare $version build $build"
  git tag -a $tag -m "DSH Swift $version"
  git push origin main
  git push origin $tag
  gh release create $tag --title $tag --notes-file $notes_file "$dmg"
EOF
	exit 0
fi

step "Publish"
git add Version.xcconfig README.md appcast-swift.xml
git commit -m "release: prepare $version build $build"
git tag -a "$tag" -m "DSH Swift $version"
git push origin main
git push origin "$tag"
gh release create "$tag" --title "$tag" --notes-file "$notes_file" "$dmg"

printf '\nReleased %s\n  DMG:    %s\n  length: %s\n  sha256: %s\n' "$tag" "$dmg" "$length" "$digest"
