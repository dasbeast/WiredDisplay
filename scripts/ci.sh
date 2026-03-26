#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/clang-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$ROOT_DIR/.build/swiftpm-module-cache}"

mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"

swift test --parallel

xcodebuild -project WiredDisplay.xcodeproj -scheme DisplaySender -configuration Debug -destination 'platform=macOS' build
xcodebuild -project WiredDisplay.xcodeproj -scheme DisplayReceiver -configuration Debug -destination 'platform=macOS' build
