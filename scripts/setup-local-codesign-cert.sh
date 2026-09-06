#!/usr/bin/env bash
set -euo pipefail

# Create (or confirm) a persistent self-signed code-signing identity in the
# login keychain. Signing DSH with this certificate keeps the TCC code
# requirement stable across rebuilds, so replacing the app no longer
# invalidates grants such as Screen Recording.
#
# The private key lives only in the Keychain and must never be committed.
# Trusting the certificate is NOT required: TCC matches the code requirement
# by certificate identity, and codesign --verify validates the seal without a
# trust evaluation.

CERT_CN="${DSH_LOCAL_CERT_CN:-DSH Local Dev}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning 2>/dev/null | grep -qF "\"${CERT_CN}\""; then
	echo "Code-signing identity '${CERT_CN}' already exists in the login keychain:"
	security find-identity -p codesigning | grep -F "\"${CERT_CN}\""
	exit 0
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dsh-local-cert.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

# Self-signed code-signing certificate (RSA 2048, 10 years, codeSigning EKU).
openssl req -x509 -newkey rsa:2048 -keyout "${TMP_DIR}/cs.key" -out "${TMP_DIR}/cs.crt" \
	-days 3650 -nodes -subj "/CN=${CERT_CN}" \
	-addext "keyUsage=digitalSignature" -addext "extendedKeyUsage=codeSigning" >/dev/null 2>&1

security import "${TMP_DIR}/cs.crt" -k "${KEYCHAIN}" >/dev/null
security import "${TMP_DIR}/cs.key" -k "${KEYCHAIN}" >/dev/null

echo "Created code-signing identity '${CERT_CN}' in the login keychain:"
security find-identity -p codesigning | grep -F "\"${CERT_CN}\""

cat <<NOTE

Use it for DSH builds:
  DSH_CODESIGN_IDENTITY='${CERT_CN}' bash scripts/release-local.sh arm64
(or set DSH_CODESIGN_IDENTITY='${CERT_CN}' in the environment once).

The certificate shows as "not trusted" (CSSMERR_TP_NOT_TRUSTED); that is
expected and does not affect code-signature verification or TCC requirement
matching. First launch of a quarantined build still needs right-click -> Open.
NOTE