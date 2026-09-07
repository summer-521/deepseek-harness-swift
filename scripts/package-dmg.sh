#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_NAME="DSH"
SWIFT_VERSION_CONFIG="${PROJECT_DIR}/Version.xcconfig"
APP_VERSION="$(sed -nE 's/^[[:space:]]*SWIFT_APP_VERSION[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "${SWIFT_VERSION_CONFIG}" | head -n 1)"
DIST_DIR="${SWIFT_DIST_DIR:-${PROJECT_DIR}/dist}"
BUILD_DIR="${PROJECT_DIR}/.build"
VOLUME_NAME="DSH Desktop ${APP_VERSION}"

if [ -z "${APP_VERSION}" ]; then
	echo "Swift application version is missing: ${SWIFT_VERSION_CONFIG}" >&2
	exit 1
fi

HOST_ARCHITECTURE="$(uname -m)"
if [ "${HOST_ARCHITECTURE}" != "arm64" ]; then
	echo "Unsupported package host architecture: ${HOST_ARCHITECTURE}; DSH packages require Apple Silicon (arm64)" >&2
	exit 1
fi

PACKAGE_ARCHES=(arm64)
if [ -n "${DSH_BUILD_ARCHES:-}" ]; then
	read -r -a REQUESTED_PACKAGE_ARCHES <<< "${DSH_BUILD_ARCHES}"
	if [ "${#REQUESTED_PACKAGE_ARCHES[@]}" -ne 1 ] || [ "${REQUESTED_PACKAGE_ARCHES[0]}" != "arm64" ]; then
		echo "Unsupported package architecture: ${DSH_BUILD_ARCHES}; only arm64 is supported" >&2
		exit 1
	fi
elif [ -n "${DSH_BUILD_ARCH:-}" ] && [ "${DSH_BUILD_ARCH}" != "arm64" ]; then
	echo "Unsupported package architecture: ${DSH_BUILD_ARCH}; only arm64 is supported" >&2
	exit 1
fi

for PACKAGE_ARCH in "${PACKAGE_ARCHES[@]}"; do
	ARTIFACT_ARCH="arm64"

	APP_DIR="${DIST_DIR}/${PACKAGE_ARCH}/${APP_NAME}.app"
	APP_BINARY="${APP_DIR}/Contents/MacOS/${APP_NAME}"
	DMG_PATH="${DIST_DIR}/DSH-Desktop-${APP_VERSION}-${ARTIFACT_ARCH}.dmg"

	if [ ! -d "${APP_DIR}" ] || [ ! -x "${APP_BINARY}" ]; then
		echo "Swift application bundle is missing for ${PACKAGE_ARCH}: ${APP_DIR}" >&2
		echo "Run scripts/build-app.sh for ${PACKAGE_ARCH} first." >&2
		exit 1
	fi

	ACTUAL_ARCH="$(lipo -archs "${APP_BINARY}")"
	if [ "${ACTUAL_ARCH}" != "${PACKAGE_ARCH}" ]; then
		echo "Expected ${APP_BINARY} to contain only ${PACKAGE_ARCH}, found: ${ACTUAL_ARCH}" >&2
		exit 1
	fi

	codesign --verify --deep --strict "${APP_DIR}"

	STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dsh-swift-dmg.XXXXXX")"
	cleanup() {
		rm -rf "${STAGING_DIR}"
	}
	trap cleanup EXIT

	# Finder metadata is not needed in the image and can carry restricted
	# provenance attributes from locally built dependencies.
	COPYFILE_DISABLE=1 cp -R "${APP_DIR}" "${STAGING_DIR}/${APP_NAME}.app"
	codesign --verify --deep --strict "${STAGING_DIR}/${APP_NAME}.app"
	ln -s /Applications "${STAGING_DIR}/Applications"

	# A bare hdiutil image opens with Finder defaults (small icons,
	# alphabetical order). Build through a read-write image so the volume
	# ships a fixed presentation: large icons, DSH.app left, a
	# drag-to-Applications target right.
	STAGING_MB="$(du -sm "${STAGING_DIR}" | cut -f1)"
	RW_MB="$((STAGING_MB + 120))"
	RW_DMG="$(mktemp "${TMPDIR:-/tmp}/dsh-swift-dmg-rw.XXXXXX").dmg"
	rm -f "${RW_DMG}"
	hdiutil create \
		-size "${RW_MB}m" \
		-fs HFS+ \
		-volname "${VOLUME_NAME}" \
		"${RW_DMG}"
	MOUNT_VOL="/Volumes/${VOLUME_NAME}"
	hdiutil attach -readwrite -noverify -noautoopen "${RW_DMG}" >/dev/null
	COPYFILE_DISABLE=1 cp -R "${STAGING_DIR}/${APP_NAME}.app" "${STAGING_DIR}/Applications" "${MOUNT_VOL}/"
	# Force Finder to register the new volume before scripting it.
	open "${MOUNT_VOL}"
	sleep 2
	APPLY_LAYOUT=0
	for _attempt in 1 2 3 4 5; do
		if osascript <<APPLESCRIPT; then
tell application "Finder"
	set mountAlias to POSIX file "${MOUNT_VOL}" as alias
	open mountAlias
	delay 1
	set wc to container window of mountAlias
	set current view of wc to icon view
	set toolbar visible of wc to false
	set statusbar visible of wc to false
	set the bounds of wc to {400, 100, 1040, 540}
	set viewOptions to the icon view options of wc
	set arrangement of viewOptions to not arranged
	set icon size of viewOptions to 128
	set position of item "${APP_NAME}.app" of wc to {170, 220}
	set position of item "Applications" of wc to {470, 220}
	close wc
	open mountAlias
	delay 1
	update mountAlias without registering applications
	delay 2
end tell
APPLESCRIPT
			APPLY_LAYOUT=1
			break
		fi
		sleep 3
	done
	if [ "${APPLY_LAYOUT}" != "1" ]; then
		echo "Finder layout scripting failed for ${VOLUME_NAME}" >&2
		hdiutil detach "${MOUNT_VOL}" >/dev/null 2>&1 || true
		rm -f "${RW_DMG}"
		exit 1
	fi
	sync
	hdiutil detach "${MOUNT_VOL}" >/dev/null

	echo "Creating ${ARTIFACT_ARCH} DMG: ${DMG_PATH}"
	hdiutil convert "${RW_DMG}" \
		-format UDZO \
		-imagekey zlib-level=9 \
		-ov \
		-o "${DMG_PATH}"
	rm -f "${RW_DMG}"
	hdiutil verify "${DMG_PATH}"

	cleanup
	trap - EXIT
	echo "✅ ${ARTIFACT_ARCH} DMG completed: ${DMG_PATH}"
done

# The derived Xcode products are only needed while producing the application
# bundles. Keep them when packaging fails for diagnostics, but remove them
# after every requested architecture has produced a verified DMG.
if [ -d "${BUILD_DIR}" ]; then
	rm -rf "${BUILD_DIR}"
	echo "✅ Cleaned Swift build artifacts: ${BUILD_DIR}"
fi
