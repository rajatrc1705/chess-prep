#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_PACKAGE_PATH="$ROOT_DIR/macos-app/ChessPrepApp"
APP_NAME="ChessPrepApp"
VERSION="${1:-v0.2.0-rc1}"
ARTIFACT_DIR="$ROOT_DIR/release-artifacts/$VERSION"
DERIVED_DATA="$ARTIFACT_DIR/DerivedData"
BUILD_PRODUCTS_DIR="$DERIVED_DATA/Build/Products/Release"
BUILT_APP_PATH="$BUILD_PRODUCTS_DIR/${APP_NAME}.app"
EXECUTABLE_PATH="$BUILD_PRODUCTS_DIR/${APP_NAME}"
RESOURCE_BUNDLE_PATH="$BUILD_PRODUCTS_DIR/${APP_NAME}_${APP_NAME}.bundle"
APP_PATH="$ARTIFACT_DIR/${APP_NAME}.app"
ZIP_PATH="$ARTIFACT_DIR/${APP_NAME}-${VERSION}.zip"
DMG_PATH="$ARTIFACT_DIR/${APP_NAME}-${VERSION}.dmg"
MANIFEST_PATH="$ARTIFACT_DIR/SHA256SUMS.txt"
BACKEND_RELEASE_BINARY="$ROOT_DIR/target/release/chess-prep"
BACKEND_BUNDLE_PATH="$APP_PATH/Contents/Resources/Binaries/chess-prep-backend"
ENGINE_BUNDLE_PATH="$APP_PATH/Contents/Resources/Engines/stockfish"
NOTICES_BUNDLE_PATH="$APP_PATH/Contents/Resources/THIRD_PARTY_NOTICES.txt"

resolve_stockfish_binary() {
  local candidates=(
    "${STOCKFISH_BINARY_PATH:-}"
    "/opt/homebrew/bin/stockfish"
    "/opt/homebrew/opt/stockfish/bin/stockfish"
    "/usr/local/bin/stockfish"
    "/usr/bin/stockfish"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  if command -v stockfish >/dev/null 2>&1; then
    command -v stockfish
    return 0
  fi

  return 1
}

resolve_stockfish_license() {
  if [[ -n "${STOCKFISH_LICENSE_PATH:-}" && -f "${STOCKFISH_LICENSE_PATH}" ]]; then
    echo "${STOCKFISH_LICENSE_PATH}"
    return 0
  fi

  if command -v brew >/dev/null 2>&1; then
    local brew_prefix
    brew_prefix="$(brew --prefix stockfish 2>/dev/null || true)"
    if [[ -n "$brew_prefix" && -f "$brew_prefix/Copying.txt" ]]; then
      echo "$brew_prefix/Copying.txt"
      return 0
    fi
  fi

  return 1
}

echo "Preparing release artifacts in: $ARTIFACT_DIR"
mkdir -p "$ARTIFACT_DIR"

echo "[1/8] Running quality gates..."
(
  cd "$ROOT_DIR"
  cargo test
  cargo clippy --all-targets --all-features
  swift test --package-path "$APP_PACKAGE_PATH"
)

echo "[2/8] Building Rust release backend binary..."
(
  cd "$ROOT_DIR"
  cargo build --release --manifest-path "$ROOT_DIR/Cargo.toml"
)

if [[ ! -x "$BACKEND_RELEASE_BINARY" ]]; then
  echo "Rust release backend not found at $BACKEND_RELEASE_BINARY"
  exit 1
fi

echo "[3/8] Building macOS Release app..."
(
  cd "$APP_PACKAGE_PATH"
  xcodebuild \
    -scheme "$APP_NAME" \
    -configuration Release \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    build \
    >"$ARTIFACT_DIR/xcodebuild.log"
)

rm -rf "$APP_PATH"
if [[ -d "$BUILT_APP_PATH" ]]; then
  ditto "$BUILT_APP_PATH" "$APP_PATH"
elif [[ -x "$EXECUTABLE_PATH" ]]; then
  mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
  cp "$EXECUTABLE_PATH" "$APP_PATH/Contents/MacOS/$APP_NAME"
  if [[ -d "$RESOURCE_BUNDLE_PATH" ]]; then
    ditto "$RESOURCE_BUNDLE_PATH" "$APP_PATH/Contents/Resources/$(basename "$RESOURCE_BUNDLE_PATH")"
  fi
  cat >"$APP_PATH/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>com.chessprep.app</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION#v}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION#v}</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF
else
  echo "Release app artifact not found. Checked:"
  echo "  - $BUILT_APP_PATH"
  echo "  - $EXECUTABLE_PATH"
  exit 1
fi

echo "[4/8] Embedding backend + engine payload..."
STOCKFISH_SOURCE="$(resolve_stockfish_binary || true)"
if [[ -z "$STOCKFISH_SOURCE" ]]; then
  echo "Stockfish binary not found. Set STOCKFISH_BINARY_PATH or install stockfish."
  exit 1
fi

mkdir -p "$(dirname "$BACKEND_BUNDLE_PATH")" "$(dirname "$ENGINE_BUNDLE_PATH")"
cp "$BACKEND_RELEASE_BINARY" "$BACKEND_BUNDLE_PATH"
chmod 755 "$BACKEND_BUNDLE_PATH"
cp -L "$STOCKFISH_SOURCE" "$ENGINE_BUNDLE_PATH"
chmod 755 "$ENGINE_BUNDLE_PATH"

{
  echo "ChessPrepApp Third-Party Notices"
  echo ""
  echo "Bundled engine: Stockfish"
  echo "License: GNU GPL v3"
  echo "Homepage: https://stockfishchess.org/"
  if stockfish_license_path="$(resolve_stockfish_license 2>/dev/null)"; then
    echo ""
    echo "Bundled license source: ${stockfish_license_path}"
  fi
} >"$NOTICES_BUNDLE_PATH"

if stockfish_license_path="$(resolve_stockfish_license 2>/dev/null)"; then
  {
    echo ""
    echo "----- BEGIN STOCKFISH LICENSE -----"
    cat "$stockfish_license_path"
    echo "----- END STOCKFISH LICENSE -----"
  } >>"$NOTICES_BUNDLE_PATH"
fi

echo "[5/8] Codesigning app (optional)..."
if [[ -n "${APPLE_DEVELOPER_IDENTITY:-}" ]]; then
  codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$APPLE_DEVELOPER_IDENTITY" \
    "$BACKEND_BUNDLE_PATH"
  codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$APPLE_DEVELOPER_IDENTITY" \
    "$ENGINE_BUNDLE_PATH"
  codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$APPLE_DEVELOPER_IDENTITY" \
    "$APP_PATH"
  echo "Codesigned with identity: $APPLE_DEVELOPER_IDENTITY"
else
  # Internal/testing fallback to avoid malformed unsigned bundles after embedding binaries.
  codesign --force --deep --sign - "$APP_PATH"
  echo "Applied ad-hoc codesign. Set APPLE_DEVELOPER_IDENTITY for trusted distribution."
fi

echo "[6/8] Packaging ZIP + DMG..."
rm -f "$ZIP_PATH" "$DMG_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$APP_PATH" -ov -format UDZO "$DMG_PATH" >/dev/null

echo "[7/8] Notarization (optional)..."
if [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
  xcrun notarytool submit "$ZIP_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --wait
  xcrun stapler staple "$APP_PATH" || true
  xcrun stapler staple "$DMG_PATH" || true
  echo "Notarization completed."
else
  echo "Skipping notarization. Set APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_SPECIFIC_PASSWORD."
fi

echo "[8/8] Writing checksums..."
(
  cd "$ARTIFACT_DIR"
  shasum -a 256 "$(basename "$ZIP_PATH")" "$(basename "$DMG_PATH")" >"$MANIFEST_PATH"
)

echo "Release candidate build complete."
echo "Artifacts:"
echo "  - $APP_PATH"
echo "  - $ZIP_PATH"
echo "  - $DMG_PATH"
echo "  - $MANIFEST_PATH"
