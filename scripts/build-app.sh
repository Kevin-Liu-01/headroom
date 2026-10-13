#!/bin/bash
# Builds Headroom in release, assembles and ad hoc signs Headroom.app, installs it to
# ~/Applications and the CLI to ~/.local/bin/headroom, and launches the app.
# Pass --no-launch to skip the launch and --no-install to only assemble build/Headroom.app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
LAUNCH=1
INSTALL=1
for arg in "$@"; do
  case "$arg" in
    --no-launch) LAUNCH=0 ;;
    --no-install) INSTALL=0; LAUNCH=0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

VERSION="1.0.0"
echo "==> swift build -c release"
swift build -c release
BIN="$(swift build -c release --show-bin-path)"

APP="$ROOT/build/Headroom.app"
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/HeadroomApp" "$APP/Contents/MacOS/Headroom"

ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
"$BIN/HeadroomApp" --icon "$ROOT/build/icon-1024.png"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ROOT/build/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$ROOT/build/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>Headroom</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>com.kevinliu.headroom</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Headroom</string>
  <key>CFBundleDisplayName</key><string>Headroom</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Copyright 2026 Kevin Liu. MIT license.</string>
</dict>
</plist>
PLIST

echo "==> signing ad hoc"
codesign --force --sign "${HEADROOM_SIGN_IDENTITY:--}" --identifier com.kevinliu.headroom "$APP"
codesign --verify --strict "$APP"

if [ "$INSTALL" = 1 ]; then
  echo "==> installing"
  if pgrep -x Headroom >/dev/null; then
    pkill -x Headroom || true
    for _ in $(seq 1 20); do pgrep -x Headroom >/dev/null || break; sleep 0.25; done
  fi
  mkdir -p "$HOME/Applications" "$HOME/.local/bin"
  rm -rf "$HOME/Applications/Headroom.app"
  ditto "$APP" "$HOME/Applications/Headroom.app"
  cp "$BIN/headroom" "$HOME/.local/bin/headroom.new"
  codesign --force --sign "${HEADROOM_SIGN_IDENTITY:--}" --identifier com.kevinliu.headroom.cli "$HOME/.local/bin/headroom.new"
  mv -f "$HOME/.local/bin/headroom.new" "$HOME/.local/bin/headroom"
  echo "    $HOME/Applications/Headroom.app"
  echo "    $HOME/.local/bin/headroom"
fi

if [ "$LAUNCH" = 1 ]; then
  echo "==> launching"
  open "$HOME/Applications/Headroom.app"
fi
