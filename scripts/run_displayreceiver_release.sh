#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT_DIR/scripts/release_receiver.env.example"
RELEASE_SCRIPT="$ROOT_DIR/scripts/release_displayreceiver.sh"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE" >&2
  exit 1
fi

if [[ ! -f "$RELEASE_SCRIPT" ]]; then
  echo "Missing release script: $RELEASE_SCRIPT" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

if [[ -n "${WDISPLAY_SSH_KEY_FILE:-}" && -f "$WDISPLAY_SSH_KEY_FILE" ]]; then
  if ! ssh-add -l >/dev/null 2>&1; then
    eval "$(ssh-agent -s)" >/dev/null
  fi

  ssh-add --apple-use-keychain "$WDISPLAY_SSH_KEY_FILE"
fi

exec "$RELEASE_SCRIPT"
