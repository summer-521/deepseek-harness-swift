#!/bin/bash
set -euo pipefail

NODE_VERSION="${NODE_VERSION:-v22.23.1}"
NODE_SOURCE="${DSH_NODE_SOURCE:-auto}"
REQUESTED_ARCH="${DSH_NODE_ARCH:-arm64}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEST_DIR="${PROJECT_DIR}/assets/node"

HOST_ARCHITECTURE="$(uname -m)"
if [ "$HOST_ARCHITECTURE" != "arm64" ]; then
  echo "Unsupported Node host architecture: $HOST_ARCHITECTURE; DSH requires Apple Silicon (arm64)" >&2
  exit 1
fi

mkdir -p "$DEST_DIR/bin"

if [ "$REQUESTED_ARCH" != "arm64" ]; then
  echo "Unsupported Node architecture: $REQUESTED_ARCH; only arm64 is supported" >&2
  exit 1
fi

validate_arm64_node() {
  local node_path="$1"
  local actual_architecture
  actual_architecture="$(lipo -archs "$node_path" 2>/dev/null)" || {
    echo "Unable to inspect Node architecture: $node_path" >&2
    exit 1
  }
  if [ "$actual_architecture" != "arm64" ]; then
    echo "Expected arm64 Node.js binary, found: $actual_architecture" >&2
    exit 1
  fi
}

prepare_pnpm() {
  bash "${SCRIPT_DIR}/fetch-pnpm.sh"
}

case "$NODE_SOURCE" in
  auto|official)
    ;;
  *)
    echo "Unsupported DSH_NODE_SOURCE: $NODE_SOURCE (expected auto or official)" >&2
    exit 1
    ;;
esac

if [ "$NODE_SOURCE" = "auto" ] && [ -f "$DEST_DIR/bin/node" ] && [ -x "$DEST_DIR/bin/node" ]; then
  validate_arm64_node "$DEST_DIR/bin/node"
  echo "Bundled node already exists at $DEST_DIR/bin/node ($("$DEST_DIR/bin/node" --version))"
  prepare_pnpm
  exit 0
fi

if [ "$NODE_SOURCE" = "auto" ]; then
  # If system node is present, copy it for local development builds. Release
  # builds set DSH_NODE_SOURCE=official so the packaged runtime never depends
  # on the build machine's Node binary or deployment target.
  SYSTEM_NODE="$(which node || true)"
  if [ -n "$SYSTEM_NODE" ] && [ -x "$SYSTEM_NODE" ]; then
    echo "Copying system node from $SYSTEM_NODE..."
    cp "$SYSTEM_NODE" "$DEST_DIR/bin/node"
    chmod +x "$DEST_DIR/bin/node"
    validate_arm64_node "$DEST_DIR/bin/node"
    echo "Copied system node ($("$DEST_DIR/bin/node" --version)) to $DEST_DIR/bin/node"
    prepare_pnpm
    exit 0
  fi
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
  echo "Official Node downloads require curl and tar" >&2
  exit 1
fi

download_node() {
  local tarball="node-${NODE_VERSION}-darwin-arm64.tar.gz"
  local url="https://nodejs.org/dist/${NODE_VERSION}/${tarball}"
  local archive="$TMP_DIR/$tarball"
  local extracted="$TMP_DIR/node-${NODE_VERSION}-darwin-arm64/bin/node"

  echo "Downloading official Node.js from $url..." >&2
  curl -fsSL "$url" -o "$archive"
  tar -xzf "$archive" -C "$TMP_DIR"
  if [ ! -x "$extracted" ]; then
    echo "Downloaded Node.js archive is missing its executable: $extracted" >&2
    exit 1
  fi
  printf '%s\n' "$extracted"
}

NODE_BINARY="$(download_node)"
cp "$NODE_BINARY" "$DEST_DIR/bin/node"

chmod +x "$DEST_DIR/bin/node"
validate_arm64_node "$DEST_DIR/bin/node"

if [ "$NODE_SOURCE" = "official" ]; then
  if ! "$DEST_DIR/bin/node" -e '
    const required = [
      ["Promise.withResolvers", typeof Promise.withResolvers === "function"],
      ["node:zlib.createZstdDecompress", typeof require("node:zlib").createZstdDecompress === "function"],
      ["node:module.stripTypeScriptTypes", typeof require("node:module").stripTypeScriptTypes === "function"],
    ];
    const missing = required.filter(([, available]) => !available).map(([name]) => name);
    if (missing.length) {
      console.error(`Missing Node.js runtime features: ${missing.join(", ")}`);
      process.exit(1);
    }
  '; then
    echo "Downloaded Node.js ${NODE_VERSION} does not satisfy the DSH runtime requirements" >&2
    exit 1
  fi
fi

echo "Node.js ${NODE_VERSION} (${REQUESTED_ARCH}) installed to $DEST_DIR/bin/node"
prepare_pnpm
