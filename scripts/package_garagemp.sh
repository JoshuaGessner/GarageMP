#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist/GarageMP"
BUILD_DIR="$DIST_DIR/build"
UPLOAD_ROOT="$BUILD_DIR/GarageMP"
CLIENT_SRC="$ROOT_DIR/Resources/Client/GarageMP"
SERVER_SRC="$ROOT_DIR/Resources/Server/GarageMP"
README_SRC="$ROOT_DIR/README.md"

CLIENT_ZIP_NAME="GarageMP.zip"
UPLOAD_ZIP_NAME="GarageMP.zip"

if [[ ! -d "$CLIENT_SRC" ]]; then
  echo "Client source folder missing: $CLIENT_SRC" >&2
  exit 1
fi

if [[ ! -f "$SERVER_SRC/main.lua" ]]; then
  echo "Server plugin file missing: $SERVER_SRC/main.lua" >&2
  exit 1
fi

if [[ ! -f "$README_SRC" ]]; then
  echo "Release README missing: $README_SRC" >&2
  exit 1
fi

rm -rf "$BUILD_DIR"
rm -f "$DIST_DIR"/*.zip "$DIST_DIR"/*.sha256
mkdir -p "$UPLOAD_ROOT/Resources/Client"
mkdir -p "$UPLOAD_ROOT/Resources/Server/GarageMP/data"

# Build client-side zip sent by BeamMP server to connecting clients.
(
  cd "$CLIENT_SRC"
  zip -rq "$BUILD_DIR/$CLIENT_ZIP_NAME" . -x "*.DS_Store"
)

cp "$BUILD_DIR/$CLIENT_ZIP_NAME" "$UPLOAD_ROOT/Resources/Client/$CLIENT_ZIP_NAME"
cp "$SERVER_SRC/main.lua" "$UPLOAD_ROOT/Resources/Server/GarageMP/main.lua"
cp "$README_SRC" "$UPLOAD_ROOT/README.md"

touch "$UPLOAD_ROOT/Resources/Server/GarageMP/data/.gitkeep"

(
  cd "$BUILD_DIR"
  zip -rq "$DIST_DIR/$UPLOAD_ZIP_NAME" "GarageMP" -x "*.DS_Store"
)

shasum -a 256 "$DIST_DIR/$UPLOAD_ZIP_NAME" > "$DIST_DIR/$UPLOAD_ZIP_NAME.sha256"

cat <<EOF
GarageMP release package created:
- $DIST_DIR/$UPLOAD_ZIP_NAME
- $DIST_DIR/$UPLOAD_ZIP_NAME.sha256
EOF
