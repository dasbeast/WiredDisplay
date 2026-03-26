#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/WiredDisplay.xcodeproj"
SCHEME="DisplaySender"
CONFIGURATION="Release"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/WiredDisplayReleaseBuild}"
PRIVATE_KEY_FILE="${SPARKLE_PRIVATE_KEY_FILE:-$HOME/Desktop/sparkle-private-key.txt}"
FEED_BASE_URL="${WDISPLAY_FEED_BASE_URL:-https://baileykiehl.com/WDisplay/}"
REMOTE_DIR="${WDISPLAY_REMOTE_DIR:-public_html/WDisplay}"
CODE_SIGN_IDENTITY="${WDISPLAY_CODE_SIGN_IDENTITY:-Developer ID Application: Bailey Kiehl (4V28UB843Z)}"
NOTARY_PROFILE="${WDISPLAY_NOTARY_PROFILE:-wdisplay-notary}"
SKIP_UPLOAD="${WDISPLAY_SKIP_UPLOAD:-0}"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/release_displaysender.sh

Required environment variables for upload:
  WDISPLAY_SSH_HOST        SSH host for your cPanel account
  WDISPLAY_SSH_USER        SSH username for your cPanel account

Optional environment variables:
  SPARKLE_PRIVATE_KEY_FILE Path to your Sparkle private key export
                           Default: ~/Desktop/sparkle-private-key.txt
  WDISPLAY_FEED_BASE_URL   Public HTTPS base URL for appcast + zip
                           Default: https://baileykiehl.com/WDisplay/
  WDISPLAY_REMOTE_DIR      Remote directory on the server
                           Default: public_html/WDisplay
  WDISPLAY_CODE_SIGN_IDENTITY
                           Developer ID identity used for release signing
  WDISPLAY_NOTARY_PROFILE  notarytool keychain profile name
                           Default: wdisplay-notary
  WDISPLAY_SKIP_UPLOAD     Set to 1 to build artifacts without uploading
  DERIVED_DATA_PATH        Override Xcode derived data path

Examples:
  export WDISPLAY_SSH_HOST=baileykiehl.com
  export WDISPLAY_SSH_USER=your_cpanel_user
  ./scripts/release_displaysender.sh

  WDISPLAY_SKIP_UPLOAD=1 ./scripts/release_displaysender.sh
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

sign_with_identity() {
  local target_path="$1"
  shift

  codesign \
    --force \
    --sign "$CODE_SIGN_IDENTITY" \
    --options runtime \
    "$@" \
    "$target_path"
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
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
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
RELEASE_DIR="$ROOT_DIR/release/DisplaySender-$SHORT_VERSION"
ZIP_PATH="$RELEASE_DIR/DisplaySender-$SHORT_VERSION.zip"
APPCAST_PATH="$RELEASE_DIR/appcast.xml"
NOTARY_ZIP_PATH="/tmp/DisplaySender-$SHORT_VERSION-notarize.zip"
LEGACY_NOTARY_ZIP_PATH="$RELEASE_DIR/DisplaySender-$SHORT_VERSION-notarize.zip"
DOWNLOAD_PREFIX="${FEED_BASE_URL%/}/"

mkdir -p "$RELEASE_DIR"
rm -f "$LEGACY_NOTARY_ZIP_PATH"

echo "Re-signing Sparkle helper components..."
sign_with_identity "$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
sign_with_identity "$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
sign_with_identity "$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"
sign_with_identity "$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
sign_with_identity "$APP_PATH/Contents/Frameworks/Sparkle.framework"

echo "Re-signing DisplaySender.app with Developer ID..."
sign_with_identity \
  "$APP_PATH" \
  --entitlements "$ROOT_DIR/DisplaySender/DisplaySender.entitlements"

echo "Creating notarization archive..."
rm -f "$NOTARY_ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$NOTARY_ZIP_PATH"

echo "Submitting for notarization..."
xcrun notarytool submit "$NOTARY_ZIP_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "Stapling notarization ticket..."
xcrun stapler staple "$APP_PATH"

echo "Packaging DisplaySender $SHORT_VERSION ($BUILD_VERSION)..."
rm -f "$ZIP_PATH" "$NOTARY_ZIP_PATH" "$LEGACY_NOTARY_ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "Generating appcast..."
"$GENERATE_APPCAST" \
  --ed-key-file "$PRIVATE_KEY_FILE" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  "$RELEASE_DIR"

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
echo "  ${DOWNLOAD_PREFIX}appcast.xml"
echo "  ${DOWNLOAD_PREFIX}DisplaySender-$SHORT_VERSION.zip"
