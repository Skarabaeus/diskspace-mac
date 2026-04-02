#!/usr/bin/env bash
set -euo pipefail

PROJECT="DiskSpace.xcodeproj"
SCHEME="DiskSpace"
CONFIGURATION="${1:-Release}"
BUILD_DIR="build"

echo "Building $SCHEME ($CONFIGURATION)…"

xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$BUILD_DIR" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    build

APP_PATH=$(find "$BUILD_DIR" -name "DiskSpace.app" -maxdepth 6 | head -1)

if [[ -n "$APP_PATH" ]]; then
    echo "Built: $APP_PATH"
else
    echo "Build succeeded (app bundle path not found under $BUILD_DIR)"
fi
