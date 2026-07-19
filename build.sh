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
        <string>zh-Hans</string>
    </array>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.39</string>
    <key>CFBundleVersion</key>
    <string>40</string>
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
    <key>NSAppleEventsUsageDescription</key>
    <string>MacWake reads the current track and controls playback in Spotify and Apple Music to show Now Playing in the Dynamic Island.</string>
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

echo "=== Generating App Intents metadata (Shortcuts support) ==="
# swift build doesn't run Xcode's appintentsmetadataprocessor, so Shortcuts would never
# discover our intents. The new swift-build system does emit the .swiftconstvalues the
# processor needs, so we invoke it manually and ship Metadata.appintents in Resources.
XC_APP="$(ls -d /Applications/Xcode*.app | head -1)"
TOOLCHAIN="${XC_APP}/Contents/Developer/Toolchains/XcodeDefault.xctoolchain"
AI_SDK="$(DEVELOPER_DIR=${XC_APP}/Contents/Developer xcrun --sdk macosx --show-sdk-path)"
AI_XCV="$(DEVELOPER_DIR=${XC_APP}/Contents/Developer xcodebuild -version 2>/dev/null | grep Build | awk '{print $3}')"
AI_TMP="$(mktemp -d)"
ls Sources/*.swift > "${AI_TMP}/sources.txt"
find .build/out/Intermediates.noindex/MacWake.build/Release/MacWake-p.build -name "*.swiftconstvalues" > "${AI_TMP}/constvals.txt"
if "${TOOLCHAIN}/usr/bin/appintentsmetadataprocessor" \
    --output "${AI_TMP}/out" \
    --toolchain-dir "${TOOLCHAIN}" \
    --module-name MacWake \
    --sdk-root "${AI_SDK}" \
    --xcode-version "${AI_XCV}" \
    --platform-family macOS \
    --deployment-target 14.0 \
    --target-triple arm64-apple-macos14.0 \
    --source-file-list "${AI_TMP}/sources.txt" \
    --swift-const-vals-list "${AI_TMP}/constvals.txt" \
    --binary-file .build/release/MacWake \
    --force --quiet-warnings 2>/dev/null \
    && [ -d "${AI_TMP}/out/Metadata.appintents" ]; then
    APP_SHORTCUTS_PROCESSOR="${TOOLCHAIN}/usr/bin/appshortcutstringsprocessor"
    for strings_file in Resources/*.lproj/AppShortcuts.strings; do
        [ -f "$strings_file" ] || continue
        "$APP_SHORTCUTS_PROCESSOR" \
            --source-file "$strings_file" \
            --input-data-path "${AI_TMP}/out/Metadata.appintents" \
            --platform-family macOS \
            --deployment-target 14.0
        echo "Validated App Shortcuts localization: $strings_file"
    done
    cp -R "${AI_TMP}/out/Metadata.appintents" "${RESOURCES_DIR}/Metadata.appintents"
    echo "Metadata.appintents embedded ($(ls "${AI_TMP}/out/Metadata.appintents" | wc -l | tr -d ' ') files)."
else
    echo "WARNING: App Intents metadata generation failed — Shortcuts actions won't appear."
fi
rm -rf "${AI_TMP}"

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

echo "=== Embedding WidgetKit extension ==="
# Hand-rolled .appex (no Xcode project): WidgetKit discovers it via the NSExtension
# point identifier; chronod requires the appex under Contents/PlugIns with a bundle id
# prefixed by the host app's.
WIDGET_DIR="${CONTENTS_DIR}/PlugIns/MacWakeWidget.appex"
mkdir -p "${WIDGET_DIR}/Contents/MacOS" "${WIDGET_DIR}/Contents/Resources"
cp .build/release/MacWakeWidget "${WIDGET_DIR}/Contents/MacOS/MacWakeWidget"
# The widget is its own bundle — it needs its own copies of the localization tables.
for lproj in Resources/*.lproj; do
    [ -d "$lproj" ] || continue
    cp -R "$lproj" "${WIDGET_DIR}/Contents/Resources/"
done
cat <<EOF > "${WIDGET_DIR}/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MacWakeWidget</string>
    <key>CFBundleIdentifier</key>
    <string>com.jarvisit.macwake.widget</string>
    <key>CFBundleName</key>
    <string>MacWake Widget</string>
    <key>CFBundleDisplayName</key>
    <string>MacWake</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleShortVersionString</key>
    <string>$(grep -A1 CFBundleShortVersionString "${CONTENTS_DIR}/Info.plist" | grep string | sed 's/.*<string>\(.*\)<\/string>.*/\1/')</string>
    <key>CFBundleVersion</key>
    <string>$(grep -A1 '<key>CFBundleVersion</key>' "${CONTENTS_DIR}/Info.plist" | grep string | sed 's/.*<string>\(.*\)<\/string>.*/\1/')</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.widgetkit-extension</string>
    </dict>
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

echo "=== Signing WidgetKit extension ==="
codesign --force --options runtime --timestamp \
    --entitlements "$(pwd)/MacWakeWidget.entitlements" \
    --sign "${SIGN_IDENTITY}" "${WIDGET_DIR}"

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
echo "  1. ditto -c -k --keepParent ${APP_DIR} Wake-1.37.zip"
echo "  2. xcrun notarytool submit Wake-1.37.zip --keychain-profile wake-notary --wait"
echo "  3. xcrun stapler staple ${APP_DIR} && xcrun stapler staple Wake-1.37.zip"
echo "  4. .build/artifacts/sparkle/Sparkle/bin/sign_update Wake-1.37.zip  # get EdDSA sig for appcast.xml"
