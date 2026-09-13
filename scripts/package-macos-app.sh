#!/bin/sh
set -eu
ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
BACKEND_PACKAGE=${1:?Pass the existing portable backend package directory}
OUTPUT=${2:-"${ROOT_DIR}/dist/native/DJ 4G Hub.app"}
APP_VERSION=${APP_VERSION:-0.1.0}
APP_BUILD=${APP_BUILD:-1}
case "$OUTPUT" in /*) ;; *) echo 'Output must be an absolute .app path' >&2; exit 2;; esac
case "$OUTPUT" in *.app) ;; *) echo 'Output must end in .app' >&2; exit 2;; esac
if ! printf '%s\n' "$APP_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo 'APP_VERSION must contain three numeric components, such as 0.2.0.' >&2; exit 2
fi
if ! printf '%s\n' "$APP_BUILD" | grep -Eq '^[0-9]+(\.[0-9]+){0,2}$'; then
  echo 'APP_BUILD must contain one to three numeric components.' >&2; exit 2
fi
if [ -e "$OUTPUT" ]; then echo 'Output already exists; choose another path to preserve it.' >&2; exit 1; fi
test -f "$BACKEND_PACKAGE/lib/libusb-1.0.0.dylib"
test -f "$BACKEND_PACKAGE/bin/dj4ghub-macos"
if ! command -v lipo >/dev/null 2>&1; then
  echo 'lipo is required to validate Mach-O architectures.' >&2
  exit 1
fi

BACKEND_ARCH=$(lipo -archs "$BACKEND_PACKAGE/bin/dj4ghub-macos")
case "$BACKEND_ARCH" in
  arm64|x86_64) ;;
  *) echo "Backend must be single-arch arm64 or x86_64; got ${BACKEND_ARCH}." >&2; exit 1;;
esac

if [ "${SKIP_SWIFT_TESTS:-0}" != "1" ]; then
  swift test --package-path "${ROOT_DIR}/apps/hub-macos"
fi
swift build -c release --package-path "${ROOT_DIR}/apps/hub-macos"
mkdir -p "$(dirname -- "$OUTPUT")"
STAGE=$(mktemp -d "$(dirname -- "$OUTPUT")/.dj4hub-app.XXXXXX")
trap 'rmdir "$STAGE" 2>/dev/null || true' EXIT
APP="$STAGE/DJ 4G Hub.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/backend/bin" "$APP/Contents/Resources/backend/lib"
mkdir -p "$APP/Contents/Resources/licenses"
cp "${ROOT_DIR}/apps/hub-macos/.build/release/DJ4Hub" "$APP/Contents/MacOS/DJ4Hub"
cp "${ROOT_DIR}/apps/hub-macos/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${APP_VERSION}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${APP_BUILD}" "$APP/Contents/Info.plist"
cp "${ROOT_DIR}/docs/images/dj-4g-hub-icon.png" "$APP/Contents/Resources/AppIcon.png"
ICONSET="$STAGE/AppIcon-macOS.iconset"
swift "${ROOT_DIR}/scripts/build-macos-icon.swift" "${ROOT_DIR}/docs/images/dj-4g-hub-icon.png" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon-macOS.icns"
rm "$ICONSET"/icon_*.png
rmdir "$ICONSET"
cp "$BACKEND_PACKAGE/lib/libusb-1.0.0.dylib" "$APP/Contents/Resources/backend/lib/"
cp "$BACKEND_PACKAGE/bin/dj4ghub-macos" "$APP/Contents/Resources/backend/bin/dj4ghub-macos"
cp "${ROOT_DIR}/LICENSE" "${ROOT_DIR}/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/"
cp -R "$BACKEND_PACKAGE/licenses/." "$APP/Contents/Resources/licenses/"
cp "${ROOT_DIR}/apps/hub-macos/README.md" "$APP/Contents/Resources/Native-README.md"
if [ "$(lipo -archs "$APP/Contents/MacOS/DJ4Hub")" != "$BACKEND_ARCH" ]; then
  echo "Native app architecture does not match backend package (${BACKEND_ARCH})." >&2
  exit 1
fi
if [ "$(lipo -archs "$APP/Contents/Resources/backend/lib/libusb-1.0.0.dylib")" != "$BACKEND_ARCH" ]; then
  echo "Bundled libusb architecture does not match backend package (${BACKEND_ARCH})." >&2
  exit 1
fi
if otool -L "$APP/Contents/Resources/backend/bin/dj4ghub-macos" | grep -q '/opt/homebrew\|/usr/local\|/Cellar/'; then
  echo 'Backend has a package-manager dependency. Build it with scripts/package-macos.sh.' >&2; exit 1
fi
codesign --force --sign - "$APP/Contents/Resources/backend/lib/libusb-1.0.0.dylib"
codesign --force --sign - "$APP/Contents/Resources/backend/bin/dj4ghub-macos"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
mv "$APP" "$OUTPUT"
echo "Native App: $OUTPUT"
