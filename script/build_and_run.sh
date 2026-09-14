#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="PRNotch"
BUNDLE_ID="com.prnotch.app"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
STAGED_APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
STAGED_APP_CONTENTS="$STAGED_APP_BUNDLE/Contents"
STAGED_APP_MACOS="$STAGED_APP_CONTENTS/MacOS"
STAGED_APP_BINARY="$STAGED_APP_MACOS/$APP_NAME"
INFO_PLIST="$STAGED_APP_CONTENTS/Info.plist"
INSTALL_DIR="${PR_NOTCH_INSTALL_DIR:-$HOME/Applications}"
APP_BUNDLE="$INSTALL_DIR/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
for _ in {1..30}; do
  if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  echo "$APP_NAME did not terminate; refusing to replace its running bundle" >&2
  exit 1
fi

cd "$ROOT_DIR"
if [[ "$MODE" == "clean" ]]; then
  swift package clean
  rm -rf "$STAGED_APP_BUNDLE"
  rm -rf "$APP_BUNDLE"
  echo "Cleaned Swift build artifacts and PRNotch app bundles"
  exit 0
fi

swift build -c release
BUILD_DIR="$(swift build -c release --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$APP_NAME"

rm -rf "$STAGED_APP_BUNDLE"
mkdir -p "$STAGED_APP_MACOS"
cp "$BUILD_BINARY" "$STAGED_APP_BINARY"
chmod +x "$STAGED_APP_BINARY"
/usr/bin/strip -x "$STAGED_APP_BINARY"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>PR Notch</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSMultipleInstancesProhibited</key>
  <true/>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

/usr/bin/codesign --force --deep --sign - "$STAGED_APP_BUNDLE" >/dev/null

mkdir -p "$INSTALL_DIR"
rm -rf "$APP_BUNDLE"
/usr/bin/ditto "$STAGED_APP_BUNDLE" "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE" "$@"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    for _ in {1..50}; do
      if pgrep -f "$APP_BINARY" >/dev/null; then
        echo "$APP_NAME is running from $APP_BUNDLE"
        exit 0
      fi
      sleep 0.1
    done
    echo "$APP_NAME did not stay running" >&2
    exit 1
    ;;
  --qa-expanded)
    open_app --args --qa-expanded
    ;;
  --qa-hover-stress)
    open_app --args --qa-hover-stress
    ;;
  *)
    echo "usage: $0 [clean|run|--debug|--logs|--telemetry|--verify|--qa-expanded|--qa-hover-stress]" >&2
    exit 2
    ;;
esac
