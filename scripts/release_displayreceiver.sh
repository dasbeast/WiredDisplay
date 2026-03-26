#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/WiredDisplay.xcodeproj"
SCHEME="DisplayReceiver"
CONFIGURATION="Release"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/WiredDisplayReceiverReleaseBuild}"
PRIVATE_KEY_FILE="${SPARKLE_PRIVATE_KEY_FILE:-$HOME/Desktop/sparkle-private-key.txt}"
FEED_BASE_URL="${WDISPLAY_RECEIVER_FEED_BASE_URL:-https://baileykiehl.com/WDisplay/}"
REMOTE_DIR="${WDISPLAY_RECEIVER_REMOTE_DIR:-public_html/WDisplay}"
APPCAST_FILENAME="${WDISPLAY_RECEIVER_APPCAST_FILENAME:-DisplayReceiver-appcast.xml}"
CODE_SIGN_IDENTITY="${WDISPLAY_RECEIVER_CODE_SIGN_IDENTITY:-Developer ID Application: Bailey Kiehl (4V28UB843Z)}"
NOTARY_PROFILE="${WDISPLAY_NOTARY_PROFILE:-wdisplay-notary}"
SPARKLE_PUBLIC_ED_KEY="${WDISPLAY_SPARKLE_PUBLIC_ED_KEY:-XmDzxJKWYs500FMKMsBUoRkTXqGv/KjpJXbkflHHnbI=}"
SKIP_UPLOAD="${WDISPLAY_SKIP_UPLOAD:-0}"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/release_displayreceiver.sh

Required environment variables for upload:
  WDISPLAY_SSH_HOST        SSH host for your cPanel account
  WDISPLAY_SSH_USER        SSH username for your cPanel account

Optional environment variables:
  WDISPLAY_SSH_KEY_FILE            Path to SSH private key for uploads
  SPARKLE_PRIVATE_KEY_FILE         Path to your Sparkle private key export
  WDISPLAY_RECEIVER_FEED_BASE_URL  Public HTTPS base URL for receiver files
  WDISPLAY_RECEIVER_REMOTE_DIR     Remote directory on the server
  WDISPLAY_RECEIVER_APPCAST_FILENAME
                                   Appcast filename to publish
  WDISPLAY_RECEIVER_CODE_SIGN_IDENTITY
                                   Code signing identity used after plist injection
  WDISPLAY_NOTARY_PROFILE          notarytool keychain profile name
                                   Default: wdisplay-notary
  WDISPLAY_SKIP_UPLOAD             Set to 1 to build artifacts without uploading
  DERIVED_DATA_PATH                Override Xcode derived data path
EOF
}

if [[ "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_file() {
  if [[ ! -f "$1" ]]; then
    echo "Required file not found: $1" >&2
    exit 1
  fi
}

require_command xcodebuild
require_command ditto
require_command plutil
require_command scp
require_command ssh
require_command xmllint
require_command codesign
require_command xcrun

require_file "$PRIVATE_KEY_FILE"

echo "Building $SCHEME..."
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build

APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$SCHEME.app"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
SPARKLE_BIN_DIR="$DERIVED_DATA_PATH/SourcePackages/artifacts/sparkle/Sparkle/bin"
GENERATE_APPCAST="$SPARKLE_BIN_DIR/generate_appcast"
SIGN_UPDATE="$SPARKLE_BIN_DIR/sign_update"

require_file "$APP_PATH/Contents/MacOS/$SCHEME"
require_file "$INFO_PLIST"
require_file "$GENERATE_APPCAST"
require_file "$SIGN_UPDATE"

SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
RELEASE_DIR="$ROOT_DIR/release/DisplayReceiver-$SHORT_VERSION"
ZIP_FILENAME="DisplayReceiver-$SHORT_VERSION.zip"
ZIP_PATH="$RELEASE_DIR/$ZIP_FILENAME"
APPCAST_PATH="$RELEASE_DIR/$APPCAST_FILENAME"
NOTARY_ZIP_PATH="/tmp/DisplayReceiver-$SHORT_VERSION-notarize.zip"
LEGACY_NOTARY_ZIP_PATH="$RELEASE_DIR/DisplayReceiver-$SHORT_VERSION-notarize.zip"
DOWNLOAD_PREFIX="${FEED_BASE_URL%/}/"
RECEIVER_FEED_URL="${WDISPLAY_RECEIVER_SU_FEED_URL:-${DOWNLOAD_PREFIX}${APPCAST_FILENAME}}"

mkdir -p "$RELEASE_DIR"
rm -f "$LEGACY_NOTARY_ZIP_PATH"

echo "Injecting Sparkle keys into receiver bundle..."
/usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$INFO_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "$INFO_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :SUEnableInstallerLauncherService" "$INFO_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :SUFeedURL string $RECEIVER_FEED_URL" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_ED_KEY" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :SUEnableInstallerLauncherService bool YES" "$INFO_PLIST"

echo "Re-signing DisplayReceiver.app..."
codesign \
  --force \
  --deep \
  --sign "$CODE_SIGN_IDENTITY" \
  --options runtime \
  --entitlements "$ROOT_DIR/DisplayReceiver/DisplayReceiver.entitlements" \
  "$APP_PATH"

echo "Creating notarization archive..."
rm -f "$NOTARY_ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$NOTARY_ZIP_PATH"

echo "Submitting for notarization..."
xcrun notarytool submit "$NOTARY_ZIP_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "Stapling notarization ticket..."
xcrun stapler staple "$APP_PATH"

echo "Packaging DisplayReceiver $SHORT_VERSION ($BUILD_VERSION)..."
rm -f "$ZIP_PATH" "$APPCAST_PATH" "$NOTARY_ZIP_PATH" "$LEGACY_NOTARY_ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "Generating appcast..."
"$GENERATE_APPCAST" \
  --ed-key-file "$PRIVATE_KEY_FILE" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  -o "$APPCAST_FILENAME" \
  "$RELEASE_DIR"

if [[ ! -f "$APPCAST_PATH" ]]; then
  GENERATED_APPCAST="$(find "$RELEASE_DIR" -maxdepth 1 -name '*.xml' | head -n 1)"
  if [[ -z "${GENERATED_APPCAST:-}" && -f "$ROOT_DIR/$APPCAST_FILENAME" ]]; then
    GENERATED_APPCAST="$ROOT_DIR/$APPCAST_FILENAME"
  fi
  if [[ -n "${GENERATED_APPCAST:-}" && "$GENERATED_APPCAST" != "$APPCAST_PATH" ]]; then
    mv "$GENERATED_APPCAST" "$APPCAST_PATH"
  fi
fi

if [[ ! -f "$APPCAST_PATH" ]]; then
  echo "generate_appcast did not produce $APPCAST_PATH" >&2
  exit 1
fi

SIGN_OUTPUT="$("$SIGN_UPDATE" "$ZIP_PATH" --ed-key-file "$PRIVATE_KEY_FILE")"
ED_SIGNATURE="$(echo "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
ARCHIVE_LENGTH="$(echo "$SIGN_OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"

if [[ -z "$ED_SIGNATURE" || -z "$ARCHIVE_LENGTH" ]]; then
  echo "Failed to extract Sparkle signature metadata from sign_update output." >&2
  exit 1
fi

if ! grep -q 'sparkle:edSignature=' "$APPCAST_PATH"; then
  perl -0pi -e 's#<enclosure url="([^"]+)" length="([^"]+)" type="application/octet-stream"/>#<enclosure url="$1" sparkle:edSignature="'"$ED_SIGNATURE"'" length="'"$ARCHIVE_LENGTH"'" type="application/octet-stream"/>#' "$APPCAST_PATH"
fi

xmllint --noout "$APPCAST_PATH"

echo
echo "Artifacts ready:"
echo "  $ZIP_PATH"
echo "  $APPCAST_PATH"

if [[ "$SKIP_UPLOAD" == "1" ]]; then
  echo
  echo "Skipping upload because WDISPLAY_SKIP_UPLOAD=1."
  exit 0
fi

if [[ -z "${WDISPLAY_SSH_HOST:-}" || -z "${WDISPLAY_SSH_USER:-}" ]]; then
  echo
  echo "Upload skipped because WDISPLAY_SSH_HOST and/or WDISPLAY_SSH_USER are not set." >&2
  echo "Set them and re-run, or use WDISPLAY_SKIP_UPLOAD=1." >&2
  exit 1
fi

REMOTE_TARGET="$WDISPLAY_SSH_USER@$WDISPLAY_SSH_HOST"
SSH_OPTIONS=()

if [[ -n "${WDISPLAY_SSH_KEY_FILE:-}" ]]; then
  SSH_OPTIONS+=(-i "$WDISPLAY_SSH_KEY_FILE")
fi

echo
echo "Uploading release to $REMOTE_TARGET:$REMOTE_DIR ..."
ssh "${SSH_OPTIONS[@]}" "$REMOTE_TARGET" "mkdir -p '$REMOTE_DIR'"
scp "${SSH_OPTIONS[@]}" "$ZIP_PATH" "$APPCAST_PATH" "$REMOTE_TARGET:$REMOTE_DIR/"

echo
echo "Upload complete."
echo "Check these URLs:"
echo "  ${DOWNLOAD_PREFIX}${APPCAST_FILENAME}"
echo "  ${DOWNLOAD_PREFIX}${ZIP_FILENAME}"
