#!/bin/bash
set -euo pipefail

APP_NAME="Shotshot"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

SRC_DIR="Sources"
RES_DIR="Resources"

FRAMEWORKS=(-framework AppKit -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers -framework IOKit)

# Deployment target — adjust if you need to support older macOS
DEPLOYMENT_TARGET="14.0"

WARNINGS=(-Xfrontend -warn-concurrency -Xfrontend -enable-actor-data-race-checks)

case "${1:-build}" in
  build|"")
    echo "Building $APP_NAME (Swift)..."

    rm -rf "$APP_BUNDLE"
    mkdir -p "$MACOS" "$RESOURCES"

    # Compile all Swift sources into the executable
    # We use swiftc directly (no Xcode, no SPM) to match the original project's philosophy.
    swiftc \
      -emit-executable \
      -o "$MACOS/$APP_NAME" \
      -target "arm64-apple-macos$DEPLOYMENT_TARGET" \
      -O \
      "${FRAMEWORKS[@]}" \
      $SRC_DIR/*.swift

    # Bundle resources
    cp "$RES_DIR/Info.plist" "$CONTENTS/"

    # Ad-hoc sign (important for TCC / permissions)
    codesign --deep --force --sign - "$APP_BUNDLE"

    echo "Built $APP_BUNDLE"
    ;;

  run)
    "$0" build
    open "$APP_BUNDLE"
    ;;

  debug)
    # Build without optimizations and with debug info for easier debugging
    echo "Building $APP_NAME (debug)..."

    rm -rf "$APP_BUNDLE"
    mkdir -p "$MACOS" "$RESOURCES"

    swiftc \
      -emit-executable \
      -o "$MACOS/$APP_NAME" \
      -target "arm64-apple-macos$DEPLOYMENT_TARGET" \
      -g -Onone -D DEBUG \
      "${FRAMEWORKS[@]}" \
      $SRC_DIR/*.swift

    cp "$RES_DIR/Info.plist" "$CONTENTS/"
    codesign --deep --force --sign - "$APP_BUNDLE"

    INSTALLED_APP="/Applications/$APP_NAME.app"

    if [ -x "$INSTALLED_APP/Contents/MacOS/$APP_NAME" ]; then
        echo "Launching installed version from /Applications (stdout/stderr will appear here)..."
        exec "$INSTALLED_APP/Contents/MacOS/$APP_NAME"
    else
        echo "No installed version found in /Applications."
        echo "Run './build.sh install' first (requires sudo) to place it there for reliable permissions."
        echo "Falling back to local build (permissions may be unreliable)..."
        exec "$MACOS/$APP_NAME"
    fi
    ;;

  install|dev)
    "$0" build

    echo "Installing to /Applications for reliable permissions..."
    sudo rm -rf "/Applications/$APP_NAME.app"
    sudo cp -R "$APP_BUNDLE" "/Applications/"

    # Re-sign the installed copy (important for TCC)
    sudo codesign --force --deep --sign - "/Applications/$APP_NAME.app"

    echo "Installed to /Applications/$APP_NAME.app"
    ;;

  test)
    echo "Running unit tests..."
    mkdir -p "$BUILD_DIR"
    TEST_BIN="$BUILD_DIR/shotshot-tests"
    # swiftc requires the entry-point file to be named main.swift in multi-file builds.
    TEST_MAIN="$BUILD_DIR/main.swift"
    cp Tests/run_tests.swift "$TEST_MAIN"
    swiftc \
      -o "$TEST_BIN" \
      -target "arm64-apple-macos$DEPLOYMENT_TARGET" \
      -g -Onone \
      -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers \
      Sources/CaptureStore.swift \
      Sources/Annotation.swift \
      Sources/AnnotationRenderer.swift \
      "$TEST_MAIN"
    "$TEST_BIN"
    ;;

  clean)
    rm -rf "$BUILD_DIR"
    echo "Cleaned build directory"
    ;;

  *)
    echo "Usage: $0 [build|run|debug|install|test|clean]"
    exit 1
    ;;
esac
