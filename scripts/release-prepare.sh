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

# Scratch space for the copied signing tool. Removed on every exit path,
# including a failure.
work_directory="$(mktemp -d "${TMPDIR:-/tmp}/dsh-release.XXXXXX")"
cleanup() { rm -rf "$work_directory"; }
trap cleanup EXIT

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must look like 1.2.6, got: $version"
[[ "$build" =~ ^[0-9]+$ ]] || fail "build must be a whole number, got: $build"
[[ -n "$notes_file" && -s "$notes_file" ]] || fail "--notes must name a non-empty release-notes file"
[[ "$(uname -m)" == arm64 ]] || fail "releases are built on Apple Silicon only"
command -v node >/dev/null || fail "node is required"
command -v gh >/dev/null || fail "gh is required for --publish"

tag="v$version"
dmg="$dist_directory/DSH-Desktop-$version-arm64.dmg"

step "Preflight"
# A resumed release is the normal case after any failure: prepare has already
# rewritten these three files, so they may be dirty — but nothing else may be.
release_files=(Version.xcconfig README.md appcast-swift.xml)
while IFS= read -r line; do
	[[ -z "$line" ]] && continue
	path="${line:3}"
	case " ${release_files[*]} " in
		*" $path "*) ;;
		*) fail "uncommitted changes outside the release files: $path" ;;
	esac
done < <(git status --porcelain --untracked-files=no)
[[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || fail "releases are cut from main"
git fetch --quiet origin main
git merge-base --is-ancestor origin/main HEAD \
	|| fail "local main has diverged from origin/main; fast-forward or rebase first"

# Fail in seconds, before anything is rewritten or built, when the release cannot
# reach its users: a lower build number is invisible to Sparkle however correct
# the version looks.
node "$repository_directory/scripts/release-metadata.mjs" guard --version "$version" --build "$build"

# The feed `origin/main` serves is the record of what is already public. A
# version and build that appear there have a DMG whose length and Sparkle
# signature every installed client is verifying its download against, so
# rebuilding that release would upload different bytes under the signature the
# public feed still advertises. This is not hypothetical: a push whose connection
# drops after the upload can fail locally and succeed remotely, and re-running
# the same release is then the obvious — and wrong — thing to do.
git show origin/main:appcast-swift.xml > "$work_directory/appcast-public.xml" 2>/dev/null \
	|| fail "origin/main does not carry appcast-swift.xml, so what is published cannot be established"
published_status=0
node "$repository_directory/scripts/release-metadata.mjs" published \
	--version "$version" --build "$build" --appcast "$work_directory/appcast-public.xml" \
	> "$work_directory/published.txt" || published_status=$?
# Exit 1 is the answer this release builds on: the feed was read and does not
# carry this version yet. Exit 2 means it could not be read at all, and a feed
# nobody could read answers 1 for every version — so it must never be the answer
# that starts a build.
if [[ "$published_status" != 0 && "$published_status" != 1 ]]; then
	fail "origin/main's appcast-swift.xml could not be read (release-metadata exited $published_status), so whether $tag is already public cannot be established"
fi
if [[ "$published_status" == 0 ]]; then
	published_length="$(sed -nE 's/^length=([0-9]+)$/\1/p' "$work_directory/published.txt" | head -n 1)"
	published_url="$(sed -nE 's/^url=(.+)$/\1/p' "$work_directory/published.txt" | head -n 1)"
	published_signature="$(sed -nE 's/^signature=(.+)$/\1/p' "$work_directory/published.txt" | head -n 1)"
	step "$tag is already published"
	# The only work left is checking that what the feed advertises is what the
	# release actually carries. Nothing may be rebuilt or re-uploaded.
	if $dry_run; then
		echo "nothing to do: $version (build $build) is already public"
		echo "re-run without --dry-run to verify the published asset against the feed"
		exit 0
	fi
	bash "$repository_directory/scripts/release-verify-asset.sh" \
		--feed "$tag" "$published_url" "$published_length" --signature "$published_signature"
	echo "nothing to do: $version (build $build) is public and its asset matches the feed"
	echo "to ship a change, release a new build or version"
	exit 0
fi

# The tag may already exist when a previous attempt died after tagging, but it
# must not be moved: that is the only record of what was built. It also has to
# already describe this exact release — same commit, clean release files, and
# version config already at the target — because anything the publish step would
# still commit moves HEAD past the tag and leaves the artifact, the appcast and
# the tag with three different ideas of what was released.
resuming_release=false
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
	[[ "$(git rev-list -n 1 "$tag")" == "$(git rev-parse HEAD)" ]] \
		|| fail "tag $tag already exists on another commit; refusing to move it"
	[[ -z "$(git status --porcelain -- "${release_files[@]}")" ]] \
		|| fail "tag $tag exists but ${release_files[*]} have uncommitted changes; commit or discard them first"
	node "$repository_directory/scripts/release-metadata.mjs" bump \
		--version "$version" --build "$build" >/dev/null 2>&1 \
		|| fail "tag $tag exists but Version.xcconfig/README do not describe $version (build $build); release a new build instead"
	resuming_release=true
	echo "resuming: tag $tag already points at HEAD and describes $version (build $build)"
fi
echo "releasing $version (build $build) as $tag"

# The tag is already pushed by an attempt that died before its GitHub release
# existed, so it cannot move and the artifact it names is the only one this
# release may ever upload. Rebuilding would produce different bytes, rewrite the
# appcast, and need a commit that moves HEAD past the tag — which the check above
# would then correctly refuse. The artifact is therefore identified and proven
# here, before anything is built: the appcast item says which bytes and which
# signature this release publishes, and the file on disk has to be those bytes.
# When that cannot be shown, the release stops and asks for a new build instead.
resume_length=""
resume_signature=""
	if $resuming_release; then
		resume_status=0
		node "$repository_directory/scripts/release-metadata.mjs" published \
			--version "$version" --build "$build" > "$work_directory/release-item.txt" \
			|| resume_status=$?
		# 1 is "the local feed was read and does not describe this release"; 2 is
		# "the local feed could not be read", which is a different failure and
		# gets a message that says so.
		[[ "$resume_status" == 0 || "$resume_status" == 1 ]] \
			|| fail "the appcast could not be read (release-metadata exited $resume_status), so the artifact tag $tag names cannot be identified; release a new build or version instead of rebuilding a tagged release"
		[[ "$resume_status" == 0 ]] \
			|| fail "tag $tag exists but the local appcast does not describe $version (build $build), so the artifact it names cannot be identified; release a new build or version instead of rebuilding a tagged release"
	resume_length="$(sed -nE 's/^length=([0-9]+)$/\1/p' "$work_directory/release-item.txt" | head -n 1)"
	resume_signature="$(sed -nE 's/^signature=(.+)$/\1/p' "$work_directory/release-item.txt" | head -n 1)"
	[[ -n "$resume_length" && -n "$resume_signature" ]] \
		|| fail "the appcast item for $tag carries no length or no signature, so the artifact cannot be identified; release a new build or version"
	[[ -f "$dmg" ]] \
		|| fail "tag $tag describes $(basename "$dmg"), which is not on disk; a rebuild would produce different bytes under a tag that cannot move — release a new build or version"
	[[ "$(stat -f%z "$dmg")" == "$resume_length" ]] \
		|| fail "$(basename "$dmg") is $(stat -f%z "$dmg") bytes but tag $tag's appcast describes $resume_length; refusing to rebuild a tagged release"
	# A size does not identify a file, and the signature is what every installed
	# copy verifies: proving it here is what makes reusing this artifact safe.
	bash "$repository_directory/scripts/verify-sparkle-signature.sh" "$resume_signature" "$dmg"
	echo "reusing the artifact this release already built: $dmg ($resume_length bytes)"
fi

if $dry_run; then
	printf '%s\n' \
		"Plan for $tag:" \
		"  1. npm test$($run_tests || echo ' (skipped)')" \
		"  2. bump Version.xcconfig and the three README references" \
		"  3. scripts/build-app.sh, then copy Sparkle's sign_update out of .build, then scripts/package-dmg.sh → $dmg" \
		"  4. sign the DMG with Sparkle account $sparkle_account" \
		"  5. write the newest appcast item with that length and signature" \
		"  6. release commit, annotated tag, push tag, create the release and verify the uploaded bytes, then push main (the feed)$($publish || echo ' (prepare only; pass --publish to continue)')"
	if $resuming_release; then
		printf '%s\n' "This run reuses the artifact tag $tag already names (steps 3-5 are skipped)."
	fi
	exit 0
fi

if $run_tests; then
	step "Test the current release content"
	npm test
fi

step "Bump release metadata"
node "$repository_directory/scripts/release-metadata.mjs" bump --version "$version" --build "$build" --write
node "$repository_directory/scripts/release-metadata.mjs" show

if $resuming_release; then
	# The tag cannot move, so the bytes it already names are the only artifact
	# this release may upload: they were identified and signature-checked in
	# preflight, and rebuilt here they would be different bytes.
	step "Reuse the artifact this release already built"
	length="$resume_length"
	signature="$resume_signature"
	digest="$(shasum -a 256 "$dmg" | awk '{print $1}')"
	echo "artifact: $dmg"
	echo "length:   $length"
	echo "sha256:   $digest"
else
	step "Build and package"
	# Sparkle's signing tool lives in the SPM checkout that `build-app.sh` creates
	# under `.build`, and `package-dmg.sh` deletes `.build` once the DMG verifies.
	# The tool is therefore copied out between the two steps: a release flow that
	# runs the packager first and looks for it afterwards can only ever fail.
	bash "$repository_directory/scripts/build-app.sh"
	sign_update_source=""
	while IFS= read -r candidate; do
		sign_update_source="$candidate"
		break
	done < <(find "$repository_directory/.build" -maxdepth 8 -name sign_update -path '*sparkle*' -not -path '*old_dsa_scripts*' 2>/dev/null | head -n 1)
	[[ -n "$sign_update_source" ]] || fail "Sparkle's sign_update was not found under .build after the build; install the Sparkle tools and retry"
	sign_update="$work_directory/sign_update"
	cp "$sign_update_source" "$sign_update"
	chmod +x "$sign_update"

	bash "$repository_directory/scripts/package-dmg.sh"
	[[ -f "$dmg" ]] || fail "the packager did not produce $dmg"

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
	# The signature is only worth publishing if the client can verify it, and the
	# client uses the key this app ships. Checking here catches a key that does
	# not match the signing account before anything is uploaded.
	bash "$repository_directory/scripts/verify-sparkle-signature.sh" "$signature" "$dmg"

	step "Write the appcast item"
	node "$repository_directory/scripts/release-metadata.mjs" appcast \
		--version "$version" --build "$build" \
		--length "$length" --signature "$signature" \
		--notes-file "$notes_file" --write
fi
node --test "$repository_directory/test/swift-release-consistency.test.js"

if ! $publish; then
	step "Prepared, not published"
	# The printed commands are meant to be copied, so every path goes in with the
	# quoting it needs: a notes file under "Release Notes" would otherwise arrive
	# as three arguments. A resumed release already has its commit and its tag,
	# and the tag cannot move, so `git tag -a` is printed only when it still has
	# to run — for a tag that exists it could only fail.
	printf -v quoted_notes '%q' "$notes_file"
	printf -v quoted_dmg '%q' "$dmg"
	if $resuming_release; then
		commit_steps="  # the release commit and tag $tag already exist"
	else
		printf -v commit_steps '  git add %s\n  git commit -m "release: prepare %s build %s"\n  git tag -a %s -m "DSH Swift %s"' \
			"${release_files[*]}" "$version" "$build" "$tag" "$version"
	fi
	cat <<EOF
Next steps — or re-run this script with --publish, which is resumable and does
all of them. The order matters: the artifact is uploaded and verified first, and
main — which carries the appcast — is pushed last, so the feed never points at a
download that does not exist yet.
$commit_steps
  git push origin $tag
  if gh release view $tag >/dev/null 2>&1; then
    gh release upload $tag $quoted_dmg --clobber
  else
    gh release create $tag --title $tag --notes-file $quoted_notes $quoted_dmg
  fi
  bash scripts/release-verify-asset.sh $tag $quoted_dmg $digest --signature '$signature'
  git push origin main
EOF
	exit 0
fi

step "Publish"
# Every step here is safe to repeat: a release that died halfway is resumed by
# running this script again with the same version and build.
git add "${release_files[@]}"
if git diff --cached --quiet; then
	echo "release commit already exists: $(git log -1 --format=%s)"
else
	git commit -m "release: prepare $version build $build"
fi
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
	# Preflight compared the tag with the HEAD it found; committing the release
	# files above may have moved HEAD since, and a tag left on the previous
	# commit would publish an artifact the tag does not describe.
	tag_commit="$(git rev-list -n 1 "$tag")"
	[[ "$tag_commit" == "$(git rev-parse HEAD)" ]] \
		|| fail "tag $tag points at ${tag_commit:0:12} but HEAD is $(git rev-parse HEAD | cut -c1-12); the release commit moved after the tag was created — delete the tag and restart the release"
	echo "tag $tag already points at HEAD"
else
	git tag -a "$tag" -m "DSH Swift $version"
fi

# The artifact must exist, and be verified byte for byte, before the feed that
# points at it becomes public: `main` carries the appcast, so pushing main
# before the upload would publish an update whose download 404s.
git push origin "$tag"
if gh release view "$tag" >/dev/null 2>&1; then
	gh release upload "$tag" "$dmg" --clobber
else
	gh release create "$tag" --title "$tag" --notes-file "$notes_file" "$dmg"
fi
bash "$repository_directory/scripts/release-verify-asset.sh" \
	"$tag" "$dmg" "$digest" --signature "$signature"
git push origin main

printf '\nReleased %s\n  DMG:    %s\n  length: %s\n  sha256: %s\n' "$tag" "$dmg" "$length" "$digest"
