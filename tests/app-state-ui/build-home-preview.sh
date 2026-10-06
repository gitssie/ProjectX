#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(mktemp -d "${TMPDIR:-/tmp}/px-home-preview.XXXXXX")
app="$output/HomePreview.app"
mkdir -p "$app/zh-Hans.lproj" "$app/en.lproj"
cp -f "$root/zh-Hans.lproj/Localizable.strings" "$app/zh-Hans.lproj/"
cp -f "$root/en.lproj/Localizable.strings" "$app/en.lproj/"
python3 "$root/tests/app-state-ui/HomePreview.py" "$output/Home.m"
xcrun --sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=15.0 \
    -fobjc-arc -DPROJECTX_PATHS_TESTING -Wall -Wextra -Werror -I"$root" \
    "$output/Home.m" "$root/PXAppBackupGridView.m" "$root/PXEnvironmentPolicy.m" \
    "$root/PXRootHidePath.m" "$root/GraphicsIdentity.m" \
    "$root/PXProjectXEnvironmentOperations.m" "$root/tests/app-state-ui/OperationsModeTests.m" \
    -framework UIKit -framework Foundation -framework CoreGraphics -framework Metal -framework OpenGLES -o "$app/HomePreview"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.projectx.homepreview</string>
<key>CFBundleExecutable</key><string>HomePreview</string>
<key>CFBundleName</key><string>HomePreview</string>
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
