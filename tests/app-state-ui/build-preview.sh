#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(mktemp -d "${TMPDIR:-/tmp}/px-app-state-preview.XXXXXX")
app="$output/AppStatePreview.app"
mkdir -p "$app/zh-Hans.lproj" "$app/en.lproj"
cp -f "$root/zh-Hans.lproj/Localizable.strings" "$app/zh-Hans.lproj/"
cp -f "$root/en.lproj/Localizable.strings" "$app/en.lproj/"
xcrun --sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=15.0 \
    -fobjc-arc -Wall -Wextra -Werror -I"$root" \
    "$root/AppDataBackupRestoreViewController.m" "$root/PXAppStateProgressViewController.m" "$root/PXAppBackupGridView.m" "$root/tests/app-state-ui/Preview.m" \
    -framework Foundation -framework UIKit -framework CoreGraphics -framework QuartzCore -o "$app/AppStatePreview"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.projectx.appstatepreview</string>
<key>CFBundleExecutable</key><string>AppStatePreview</string>
<key>CFBundleName</key><string>AppStatePreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSRequiresIPhoneOS</key><true/>
<key>UILaunchScreen</key><dict/>
<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
</dict></plist>
PLIST
codesign --force --sign - "$app"
printf '%s\n' "$app"
