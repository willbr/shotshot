#!/bin/bash
set -euo pipefail

APP_NAME="Shotshot"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

SRC_CORE="core/capture.c"
SRC_MAC=(mac/*.m)

FRAMEWORKS=(-framework AppKit -framework CoreGraphics -framework IOKit)

WARNINGS=(-Wall -Wextra -Wpedantic -Werror=return-type)

INCLUDES=(-I. -Ivendor)

case "${1:-build}" in
  build|"")
    echo "Building $APP_NAME..."

    rm -rf "$APP_BUNDLE"
    mkdir -p "$MACOS" "$RESOURCES"

    # Compile C + Objective-C together
    clang \
      "${WARNINGS[@]}" \
      -O2 \
      -fobjc-arc \
      -Wno-error=deprecated-declarations \
      -Wno-error=unguarded-availability \
      -Wno-error=unguarded-availability-new \
      -Wno-error=deprecated \
      "${INCLUDES[@]}" \
      "${FRAMEWORKS[@]}" \
      "$SRC_CORE" \
      "${SRC_MAC[@]}" \
      -o "$MACOS/$APP_NAME"

    # Bundle resources
    cp resources/Info.plist "$CONTENTS/"

    # Ad-hoc sign
    codesign --deep --force --sign - "$APP_BUNDLE"

    echo "Built $APP_BUNDLE"
    ;;

  run)
    "$0" build
    open "$APP_BUNDLE"
    ;;

  debug)
    "$0" build

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

  clean)
    rm -rf "$BUILD_DIR"
    echo "Cleaned build directory"
    ;;

  *)
    echo "Usage: $0 [build|run|debug|install|clean]"
    exit 1
    ;;
esac
