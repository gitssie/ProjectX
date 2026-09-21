#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
checker="$project_root/scripts/check_roothide.sh"
fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/projectx-roothide-audit-tests.XXXXXX")
trap 'rm -rf "$fixture_root"' EXIT HUP INT TERM

fake_ldid="$fixture_root/ldid"
cat > "$fake_ldid" <<EOF
#!/bin/sh
set -eu
[ "\$#" -eq 2 ] && [ "\$1" = "-e" ]
case "\$(cat "\$2")" in
    app-contract) cat "$project_root/ProjectX.entitlements" ;;
    shared-contract) cat "$project_root/ent.plist" ;;
    worker-contract) cat "$project_root/KeychainWorkerTemplate.entitlements" ;;
    *) exit 1 ;;
esac
EOF
chmod 755 "$fake_ldid"

fake_lipo="$fixture_root/lipo"
cat > "$fake_lipo" <<'EOF'
#!/bin/sh
set -eu
[ "$#" -eq 2 ] && [ "$1" = "-archs" ]
printf '%s\n' 'arm64 arm64e'
EOF
chmod 755 "$fake_lipo"

fake_otool="$fixture_root/otool"
cat > "$fake_otool" <<'EOF'
#!/bin/sh
set -eu
[ "$#" -eq 4 ] && [ "$1" = "-arch" ] && [ "$3" = "-L" ]
worker_path=$4
printf '%s:\n' "$worker_path"
case "$(cat "$worker_path")" in
    worker-contract)
        printf '\t%s (compatibility version 0.0.0, current version 0.0.0)\n' \
            '@loader_path/.jbroot/usr/lib/libroothide.dylib'
        ;;
    wrong-worker-anchor)
        printf '\t%s (compatibility version 0.0.0, current version 0.0.0)\n' \
            '/usr/lib/libroothide.dylib'
        ;;
    *) exit 1 ;;
esac
EOF
chmod 755 "$fake_otool"

export PROJECTX_LDID="$fake_ldid"
export PROJECTX_LIPO="$fake_lipo"
export PROJECTX_OTOOL="$fake_otool"

expect_failure() {
    if "$@" > /dev/null 2>&1; then
        echo "expected command to fail: $*" >&2
        exit 1
    fi
}

write_source_fixture() {
    source_root=$1
    mkdir -p "$source_root"
    cat > "$source_root/Makefile" <<'EOF'
override THEOS_PACKAGE_SCHEME := roothide
override THEOS_PACKAGE_ARCH := iphoneos-arm64e
ProjectX_CODESIGN_FLAGS = -SProjectX.entitlements
ProjectXTweak_CODESIGN_FLAGS = -Sent.plist
ProjectXLoader_CODESIGN_FLAGS = -Sent.plist
WeaponXDaemon_CODESIGN_FLAGS = -Sent.plist
ProjectXKeychainWorker_CODESIGN_FLAGS = -SKeychainWorkerTemplate.entitlements
EOF
    cat > "$source_root/control" <<'EOF'
Package: com.hydra.projectx
Architecture: iphoneos-arm64e
Depends: firmware (>= 15.0), ldid
EOF
    cat > "$source_root/Good.m" <<'EOF'
static NSString *const PXAllowedArchitecture = @"iphoneos-arm64e";
EOF
}

write_payload_fixture() {
    payload_root=$1
    layout=$2
    mkdir -p \
        "$payload_root/Applications/ProjectX.app/LaunchScreen.storyboardc" \
        "$payload_root/Library/MobileSubstrate/DynamicLibraries" \
        "$payload_root/Library/WeaponX/Guardian" \
        "$payload_root/Library/LaunchDaemons" \
        "$payload_root/Library/libSandy" \
        "$payload_root/usr/bin"
    printf 'app-contract\n' > "$payload_root/Applications/ProjectX.app/ProjectX"
    : > "$payload_root/Applications/ProjectX.app/LaunchScreen.storyboardc/LaunchScreen.nib"
    printf 'shared-contract\n' > "$payload_root/Library/MobileSubstrate/DynamicLibraries/ProjectXTweak.dylib"
    cat > "$payload_root/Library/MobileSubstrate/DynamicLibraries/ProjectXTweak.plist" <<'EOF'
<plist><dict><key>Filter</key><dict><key>Bundles</key><array><string>com.hydra.projectx.payload-loader-only</string></array></dict></dict></plist>
EOF
    printf 'shared-contract\n' > "$payload_root/Library/MobileSubstrate/DynamicLibraries/ProjectXLoader.dylib"
    cat > "$payload_root/Library/MobileSubstrate/DynamicLibraries/ProjectXLoader.plist" <<'EOF'
<plist><dict><key>Filter</key><dict><key>Bundles</key><array><string>com.apple.UIKit</string></array><key>Executables</key><array><string>SpringBoard</string></array></dict></dict></plist>
EOF
    printf 'shared-contract\n' > "$payload_root/Library/WeaponX/WeaponXDaemon"
    printf 'worker-contract\n' > "$payload_root/Library/WeaponX/ProjectXKeychainWorker"
    : > "$payload_root/usr/bin/projectx-setup"
    : > "$payload_root/usr/bin/weaponx-debug"
    chmod 755 \
        "$payload_root/Applications/ProjectX.app/ProjectX" \
        "$payload_root/Library/MobileSubstrate/DynamicLibraries/ProjectXTweak.dylib" \
        "$payload_root/Library/MobileSubstrate/DynamicLibraries/ProjectXLoader.dylib" \
        "$payload_root/Library/WeaponX/WeaponXDaemon" \
        "$payload_root/Library/WeaponX/ProjectXKeychainWorker" \
        "$payload_root/usr/bin/projectx-setup" \
        "$payload_root/usr/bin/weaponx-debug"
    cat > "$payload_root/Library/LaunchDaemons/com.hydra.weaponx.guardian.plist" <<'EOF'
<plist><dict><key>ProgramArguments</key><array><string>/Library/WeaponX/WeaponXDaemon</string></array></dict></plist>
EOF
    cat > "$payload_root/Library/libSandy/projectx_filesystem_access.plist" <<'EOF'
<plist><dict><key>extensions</key><array><string>file-read* SANDBOX_REDIRECTED_PATH=/rootfs/var/mobile/Library/*</string></array><key>sandbox-extensions</key><array><dict><key>path</key><string>/var/mobile/Library/WeaponX</string></dict></array></dict></plist>
EOF
    if [ "$layout" = "var-jb" ]; then
        mkdir -p "$payload_root/var/jb/Library"
    elif [ "$layout" = "missing-daemon" ]; then
        rm -f "$payload_root/Library/WeaponX/WeaponXDaemon"
    elif [ "$layout" = "wrong-app-entitlements" ]; then
        printf 'shared-contract\n' > "$payload_root/Applications/ProjectX.app/ProjectX"
    elif [ "$layout" = "wrong-tweak-entitlements" ]; then
        printf 'app-contract\n' > "$payload_root/Library/MobileSubstrate/DynamicLibraries/ProjectXTweak.dylib"
    elif [ "$layout" = "wrong-daemon-entitlements" ]; then
        printf 'app-contract\n' > "$payload_root/Library/WeaponX/WeaponXDaemon"
    elif [ "$layout" = "wrong-worker-anchor" ]; then
        printf 'wrong-worker-anchor\n' > "$payload_root/Library/WeaponX/ProjectXKeychainWorker"
    elif [ "$layout" = "broad-payload-filter" ]; then
        cat > "$payload_root/Library/MobileSubstrate/DynamicLibraries/ProjectXTweak.plist" <<'EOF'
<plist><dict><key>Filter</key><dict><key>Bundles</key><array><string>com.apple.UIKit</string></array></dict></dict></plist>
EOF
    fi
}

write_package_fixture() {
    package_path=$1
    architecture=$2
    layout=$3
    package_root="$fixture_root/package-$architecture-$layout"
    rm -rf "$package_root"
    mkdir -p "$package_root/control" "$package_root/data" "$package_root/archive"
    write_payload_fixture "$package_root/data" "$layout"
    cat > "$package_root/control/control" <<EOF
Package: com.hydra.projectx
Architecture: $architecture
EOF
    for maintainer_script in preinst postinst prerm; do
        : > "$package_root/control/$maintainer_script"
        chmod 755 "$package_root/control/$maintainer_script"
    done
    printf '2.0\n' > "$package_root/archive/debian-binary"
    tar -czf "$package_root/archive/control.tar.gz" -C "$package_root/control" .
    tar -czf "$package_root/archive/data.tar.gz" -C "$package_root/data" .
    rm -f "$package_path"
    (
        cd "$package_root/archive"
        ar -rcS "$package_path" debian-binary control.tar.gz data.tar.gz
    )
}

source_fixture="$fixture_root/source"
write_source_fixture "$source_fixture"
"$checker" --audit-source "$source_fixture" > /dev/null

cat > "$source_fixture/Bad.m" <<'EOF'
static NSString *const PXLegacyPath = @"/var/jb/usr/bin/tool";
EOF
expect_failure "$checker" --audit-source "$source_fixture"
rm -f "$source_fixture/Bad.m"

cat > "$source_fixture/Bad.m" <<'EOF'
NSArray *rootlessDataDirs;
EOF
expect_failure "$checker" --audit-source "$source_fixture"
rm -f "$source_fixture/Bad.m"

cat > "$source_fixture/Makefile" <<'EOF'
THEOS_PACKAGE_SCHEME = rootless
THEOS_PACKAGE_ARCH = iphoneos-arm64
EOF
expect_failure "$checker" --audit-source "$source_fixture"
write_source_fixture "$source_fixture"

staging_fixture="$fixture_root/staging"
write_payload_fixture "$staging_fixture" good
"$checker" --check-staging "$staging_fixture" > /dev/null
"$checker" --check-worker-binary "$staging_fixture" > /dev/null
ln -s "$staging_fixture" "$staging_fixture/Library/WeaponX/.jbroot"
expect_failure "$checker" --check-worker-binary "$staging_fixture"
rm -f "$staging_fixture/Library/WeaponX/.jbroot"
mkdir -p "$staging_fixture/var/jb"
expect_failure "$checker" --check-staging "$staging_fixture"

broad_payload_fixture="$fixture_root/broad-payload-staging"
write_payload_fixture "$broad_payload_fixture" broad-payload-filter
expect_failure "$checker" --check-staging "$broad_payload_fixture"

good_package="$fixture_root/good.deb"
write_package_fixture "$good_package" iphoneos-arm64e good
PROJECTX_LDID="$fake_ldid" "$checker" --check-package "$good_package" > /dev/null

wrong_arch_package="$fixture_root/wrong-arch.deb"
write_package_fixture "$wrong_arch_package" iphoneos-arm64 good
expect_failure env PROJECTX_LDID="$fake_ldid" "$checker" --check-package "$wrong_arch_package"

wrong_layout_package="$fixture_root/wrong-layout.deb"
write_package_fixture "$wrong_layout_package" iphoneos-arm64e var-jb
expect_failure env PROJECTX_LDID="$fake_ldid" "$checker" --check-package "$wrong_layout_package"

missing_daemon_package="$fixture_root/missing-daemon.deb"
write_package_fixture "$missing_daemon_package" iphoneos-arm64e missing-daemon
expect_failure env PROJECTX_LDID="$fake_ldid" "$checker" --check-package "$missing_daemon_package"

non_executable_package="$fixture_root/non-executable.deb"
write_package_fixture "$non_executable_package" iphoneos-arm64e good
non_executable_root="$fixture_root/package-iphoneos-arm64e-good"
chmod 644 "$non_executable_root/data/usr/bin/projectx-setup"
tar -czf "$non_executable_root/archive/data.tar.gz" -C "$non_executable_root/data" .
(
    cd "$non_executable_root/archive"
    ar -rcS "$non_executable_package" debian-binary control.tar.gz data.tar.gz
)
expect_failure env PROJECTX_LDID="$fake_ldid" "$checker" --check-package "$non_executable_package"

wrong_app_entitlements_package="$fixture_root/wrong-app-entitlements.deb"
write_package_fixture "$wrong_app_entitlements_package" iphoneos-arm64e wrong-app-entitlements
expect_failure env PROJECTX_LDID="$fake_ldid" "$checker" --check-package "$wrong_app_entitlements_package"

wrong_tweak_entitlements_package="$fixture_root/wrong-tweak-entitlements.deb"
write_package_fixture "$wrong_tweak_entitlements_package" iphoneos-arm64e wrong-tweak-entitlements
expect_failure env PROJECTX_LDID="$fake_ldid" "$checker" --check-package "$wrong_tweak_entitlements_package"

wrong_daemon_entitlements_package="$fixture_root/wrong-daemon-entitlements.deb"
write_package_fixture "$wrong_daemon_entitlements_package" iphoneos-arm64e wrong-daemon-entitlements
expect_failure env PROJECTX_LDID="$fake_ldid" "$checker" --check-package "$wrong_daemon_entitlements_package"

wrong_worker_anchor_package="$fixture_root/wrong-worker-anchor.deb"
write_package_fixture "$wrong_worker_anchor_package" iphoneos-arm64e wrong-worker-anchor
expect_failure "$checker" --check-package "$wrong_worker_anchor_package"

echo "RootHide audit regression tests passed."
