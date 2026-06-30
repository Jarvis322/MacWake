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
    <string>com.jarvisit.macwake</string>
    <key>CFBundleName</key>
    <string>Wake</string>
    <key>CFBundleDisplayName</key>
    <string>Wake</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>tr</string>
    </array>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.22</string>
    <key>CFBundleVersion</key>
    <string>23</string>
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
    <key>ITSAppUsesNonExemptEncryption</key>
    <false/>
    <key>SUPublicEDKey</key>
    <string>/2MkiFjUE9FNAkLrnaVSgGmy/kRMG4z5Ax7PaBW3gnM=</string>
    <key>SUFeedURL</key>
    <string>https://raw.githubusercontent.com/Jarvis322/MacWake/main/appcast.xml</string>
</dict>
</plist>
EOF

echo "=== Copying localization resources ==="
for lproj in Resources/*.lproj; do
    [ -d "$lproj" ] || continue
    cp -R "$lproj" "${RESOURCES_DIR}/"
done

echo "=== Compiling using Swift Package Manager ==="
XCODE_DIR="$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1)/Contents/Developer"
DEVELOPER_DIR="${DEVELOPER_DIR:-$XCODE_DIR}" swift build -c release

echo "=== Copying Binary to App Bundle ==="
cp .build/release/MacWake "${MACOS_DIR}/MacWake"

echo "=== Embedding command-line tool ==="
HELPERS_DIR="${CONTENTS_DIR}/Helpers"
mkdir -p "${HELPERS_DIR}"
cp .build/release/MacWakeCLI "${HELPERS_DIR}/macwake"

echo "=== Embedding privileged helper daemon ==="
cp .build/release/MacWakeHelper "${MACOS_DIR}/MacWakeHelper"
LAUNCHD_DIR="${CONTENTS_DIR}/Library/LaunchDaemons"
mkdir -p "${LAUNCHD_DIR}"
cat <<EOF > "${LAUNCHD_DIR}/com.jarvisit.macwake.helper.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.jarvisit.macwake.helper</string>
    <key>BundleProgram</key>
    <string>Contents/MacOS/MacWakeHelper</string>
    <key>MachServices</key>
    <dict>
        <key>com.jarvisit.macwake.helper</key>
        <true/>
    </dict>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>com.jarvisit.macwake</string>
    </array>
</dict>
</plist>
EOF

echo "=== Embedding Sparkle.framework ==="
FRAMEWORKS_DIR="${CONTENTS_DIR}/Frameworks"
mkdir -p "${FRAMEWORKS_DIR}"
SPARKLE_SRC=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
cp -R "${SPARKLE_SRC}" "${FRAMEWORKS_DIR}/Sparkle.framework"

SIGN_IDENTITY="Developer ID Application: YIGIT CAN POLAT (6NK6D7LL79)"
ENTITLEMENTS="$(pwd)/MacWake.entitlements"
SPARKLE_FW="${FRAMEWORKS_DIR}/Sparkle.framework"

echo "=== Adding rpath for embedded frameworks ==="
install_name_tool -add_rpath "@executable_path/../Frameworks" "${MACOS_DIR}/MacWake" 2>/dev/null || true

echo "=== Signing Sparkle internals (inside-out, with timestamp) ==="
# Step 1: sign all .xpc bundles inside Sparkle (deepest first)
while IFS= read -r xpc; do
    codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" "$xpc"
done < <(find "${SPARKLE_FW}" -name "*.xpc" | sort -r)

# Step 2: sign all .app bundles inside Sparkle
while IFS= read -r app; do
    codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" "$app"
done < <(find "${SPARKLE_FW}" -name "*.app" | sort -r)

# Step 3: sign loose Mach-O executables inside Sparkle/Versions/B (Autoupdate etc.)
while IFS= read -r f; do
    if file "$f" | grep -q "Mach-O"; then
        codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" "$f"
    fi
done < <(find "${SPARKLE_FW}/Versions/B" -maxdepth 1 -type f)

# Step 4: sign the framework itself
codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${SPARKLE_FW}"

echo "=== Signing command-line tool ==="
codesign --force --options runtime --timestamp \
    --sign "${SIGN_IDENTITY}" "${HELPERS_DIR}/macwake"

echo "=== Signing privileged helper daemon ==="
codesign --force --options runtime --timestamp \
    --sign "${SIGN_IDENTITY}" "${MACOS_DIR}/MacWakeHelper"

echo "=== Signing main binary and app bundle ==="
codesign --force --options runtime --timestamp --entitlements "${ENTITLEMENTS}" \
    --sign "${SIGN_IDENTITY}" "${MACOS_DIR}/MacWake"
codesign --force --options runtime --timestamp --entitlements "${ENTITLEMENTS}" \
    --sign "${SIGN_IDENTITY}" "${APP_DIR}"

echo "=== Verifying signature ==="
codesign --verify --deep --strict "${APP_DIR}" && echo "Signature OK" || echo "Signature FAILED"
spctl --assess --type exec "${APP_DIR}" 2>&1 || true

echo "=== Copying to /Applications ==="
cp -R "${APP_DIR}" /Applications/

echo "=== Successfully built MacWake ==="
echo ""
echo "Local copy: $(pwd)/${APP_DIR}"
echo "/Applications copy: /Applications/${APP_NAME}.app"
echo ""
echo "To notarize and distribute:"
echo "  1. ditto -c -k --keepParent ${APP_DIR} Wake-1.0.zip"
echo "  2. xcrun notarytool submit Wake-1.0.zip --keychain-profile wake-notary --wait"
echo "  3. xcrun stapler staple ${APP_DIR} && xcrun stapler staple Wake-1.0.zip"
echo "  4. .build/artifacts/sparkle/Sparkle/bin/sign_update Wake-1.0.zip  # get EdDSA sig for appcast.xml"
