#!/usr/bin/env bash
# Prove one file is the artifact a Sparkle signature describes.
#
# The public key comes from the Info.plist this app ships, so this answers the
# question that matters to a client: would Sparkle accept this file? The
# verifier is a small Swift program — Ed25519 with CryptoKit — compiled into a
# temporary directory, because the toolchain that builds the app is already
# required and the system `openssl` cannot verify Ed25519.
#
# Usage: bash scripts/verify-sparkle-signature.sh <base64 signature> <file>
#          [--info-plist <path>]
set -euo pipefail

repository_directory="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

usage() {
	printf '%s\n' 'Usage: bash scripts/verify-sparkle-signature.sh <base64 signature> <file>' >&2
}

if [[ $# -lt 2 ]]; then
	usage
	exit 2
fi

signature="$1"
file="$2"
shift 2
info_plist="${DSH_INFO_PLIST:-$repository_directory/Info.plist}"
while [[ $# -gt 0 ]]; do
	case "$1" in
		--info-plist)
			[[ $# -ge 2 ]] || { usage; exit 2; }
			info_plist="$2"
			shift 2
			;;
		*) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
	esac
done

fail() { echo "verify-sparkle-signature: $1" >&2; exit 1; }

[[ -n "$signature" ]] || fail "a base64 signature is required"
[[ -f "$file" ]] || fail "the file to verify does not exist: $file"
[[ -f "$info_plist" ]] || fail "the Info.plist carrying SUPublicEDKey does not exist: $info_plist"
command -v xcrun >/dev/null || fail "xcrun is required to build the verifier"
command -v plutil >/dev/null || fail "plutil is required"
plutil -extract SUPublicEDKey raw -o - "$info_plist" >/dev/null 2>&1 \
	|| fail "$info_plist has no SUPublicEDKey; every installed copy would reject the update"

work_directory="$(mktemp -d "${TMPDIR:-/tmp}/dsh-sparkle-verify.XXXXXX")"
cleanup() { rm -rf "$work_directory"; }
trap cleanup EXIT

verifier="$work_directory/sparkle-signature"
xcrun swiftc -O -module-cache-path "$work_directory/module-cache" \
	"$repository_directory/scripts/sparkle-signature.swift" -o "$verifier" \
	|| fail "could not build the signature verifier"

# No `exec`: it would replace this shell, and the EXIT trap that deletes the
# work directory — the compiled verifier and its module cache, about 30 MB —
# would never run. The verifier's own status is passed through explicitly.
status=0
"$verifier" "$info_plist" "$signature" "$file" || status=$?
exit "$status"
