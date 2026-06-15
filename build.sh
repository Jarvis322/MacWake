#!/bin/bash
set -e

APP_NAME="MacWake"
APP_DIR="${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "=== Cleaning previous builds ==="
rm -rf "${APP_DIR}"
rm -rf "/Applications/${APP_NAME}.app"
rm -rf .build

echo "=== Creating App Bundle Directory Structure ==="
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

echo "=== Creating AppIcon.icns ==="
if [ -f "app_icon_source.png" ]; then
    mkdir -p AppIcon.iconset
    sips -s format png -z 16 16      app_icon_source.png --out AppIcon.iconset/icon_16x16.png > /dev/null
    sips -s format png -z 32 32      app_icon_source.png --out AppIcon.iconset/icon_16x16@2x.png > /dev/null
    sips -s format png -z 32 32      app_icon_source.png --out AppIcon.iconset/icon_32x32.png > /dev/null
    sips -s format png -z 64 64      app_icon_source.png --out AppIcon.iconset/icon_32x32@2x.png > /dev/null
    sips -s format png -z 128 128    app_icon_source.png --out AppIcon.iconset/icon_128x128.png > /dev/null
    sips -s format png -z 256 256    app_icon_source.png --out AppIcon.iconset/icon_128x128@2x.png > /dev/null
    sips -s format png -z 256 256    app_icon_source.png --out AppIcon.iconset/icon_256x256.png > /dev/null
    sips -s format png -z 512 512    app_icon_source.png --out AppIcon.iconset/icon_256x256@2x.png > /dev/null
    sips -s format png -z 512 512    app_icon_source.png --out AppIcon.iconset/icon_512x512.png > /dev/null
    sips -s format png -z 1024 1024  app_icon_source.png --out AppIcon.iconset/icon_512x512@2x.png > /dev/null
    iconutil -c icns AppIcon.iconset -o AppIcon.icns
    rm -rf AppIcon.iconset
    cp AppIcon.icns "${RESOURCES_DIR}/AppIcon.icns"
    echo "AppIcon.icns created and packaged."
fi

echo "=== Creating Info.plist ==="
cat <<EOF > "${CONTENTS_DIR}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MacWake</string>
    <key>CFBundleIdentifier</key>
    <string>com.macwake</string>
    <key>CFBundleName</key>
    <string>MacWake</string>
    <key>CFBundleDisplayName</key>
    <string>MacWake</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSUIElement</key>
    <string>1</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 MacWake. All rights reserved.</string>
    <key>NSUserNotificationAlertStyle</key>
    <string>alert</string>
</dict>
</plist>
EOF

echo "=== Compiling using Swift Package Manager ==="
DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer" swift build -c release

echo "=== Copying Binary to App Bundle ==="
cp .build/release/MacWake "${MACOS_DIR}/MacWake"

echo "=== Signing App Bundle ==="
if [ "${APP_STORE_BUILD:-0}" = "1" ]; then
    codesign --force --deep --sign - --entitlements MacWake.entitlements "${APP_DIR}"
else
    codesign --force --deep --sign - "${APP_DIR}"
fi

echo "=== Copying to /Applications ==="
cp -R "${APP_DIR}" /Applications/

echo "=== Successfully built and installed MacWake to /Applications/MacWake.app ==="
