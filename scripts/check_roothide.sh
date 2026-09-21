#!/bin/sh

set -eu

cleanup_path=""
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

cleanup() {
    if [ -n "$cleanup_path" ]; then
        rm -rf "$cleanup_path"
    fi
}

trap cleanup EXIT HUP INT TERM

fail() {
    echo "error: $*" >&2
    exit 1
}

require_path() {
    root=$1
    relative_path=$2
    if [ ! -e "$root/$relative_path" ]; then
        fail "required RootHide package path is missing: /$relative_path"
    fi
}

check_source() {
    source_root=$(CDPATH= cd -- "$1" && pwd)
    makefile="$source_root/Makefile"
    control_file="$source_root/control"

    [ -f "$makefile" ] || fail "Makefile is missing from $source_root"
    [ -f "$control_file" ] || fail "control is missing from $source_root"

    if ! grep -Eq '^[[:space:]]*(override[[:space:]]+)?THEOS_PACKAGE_SCHEME[[:space:]]*:?=[[:space:]]*roothide[[:space:]]*$' "$makefile"; then
        fail "Makefile must force THEOS_PACKAGE_SCHEME to roothide"
    fi
    if ! grep -Eq '^[[:space:]]*(override[[:space:]]+)?THEOS_PACKAGE_ARCH[[:space:]]*:?=[[:space:]]*iphoneos-arm64e[[:space:]]*$' "$makefile"; then
        fail "Makefile must force THEOS_PACKAGE_ARCH to iphoneos-arm64e"
    fi
    if ! grep -Eq '^Architecture:[[:space:]]*iphoneos-arm64e[[:space:]]*$' "$control_file"; then
        fail "control must declare Architecture: iphoneos-arm64e"
    fi
    if ! grep -Eq '^[[:space:]]*ProjectX_CODESIGN_FLAGS[[:space:]]*:?=[[:space:]]*-SProjectX\.entitlements[[:space:]]*$' "$makefile"; then
        fail "ProjectX must be signed with ProjectX.entitlements"
    fi
    if ! grep -Eq '^[[:space:]]*ProjectXTweak_CODESIGN_FLAGS[[:space:]]*:?=[[:space:]]*-Sent\.plist[[:space:]]*$' "$makefile"; then
        fail "ProjectXTweak must be signed with ent.plist"
    fi
    if ! grep -Eq '^[[:space:]]*ProjectXLoader_CODESIGN_FLAGS[[:space:]]*:?=[[:space:]]*-Sent\.plist[[:space:]]*$' "$makefile"; then
        fail "ProjectXLoader must be signed with ent.plist"
    fi
    if ! grep -Eq '^[[:space:]]*WeaponXDaemon_CODESIGN_FLAGS[[:space:]]*:?=[[:space:]]*-Sent\.plist[[:space:]]*$' "$makefile"; then
        fail "WeaponXDaemon must be signed with ent.plist"
    fi
    if ! grep -Eq '^[[:space:]]*ProjectXKeychainWorker_CODESIGN_FLAGS[[:space:]]*:?=[[:space:]]*-SKeychainWorkerTemplate\.entitlements[[:space:]]*$' "$makefile"; then
        fail "ProjectXKeychainWorker must use the unprivileged template entitlement contract"
    fi
    if ! grep -Eq '^Depends:.*[[:space:],]ldid([[:space:],]|$)' "$control_file"; then
        fail "control must depend on ldid for per-operation worker signing"
    fi

    source_list=$(mktemp "${TMPDIR:-/tmp}/projectx-roothide-source.XXXXXX")
    cleanup_path=$source_list
    find "$source_root" \
        \( -path "$source_root/.git" -o \
           -path "$source_root/.beads" -o \
           -path "$source_root/.codegraph" -o \
           -path "$source_root/.theos" -o \
           -path "$source_root/_deb_extract" -o \
           -path "$source_root/build_check" -o \
           -path "$source_root/packages" -o \
           -path "$source_root/tests" \) -prune -o \
        -type f \( -name '*.c' -o -name '*.h' -o -name '*.m' -o -name '*.mm' -o \
                   -name '*.x' -o -name '*.sh' -o -name '*.plist' -o -name '*.md' -o \
                   -name 'Makefile' -o -name 'control' \) \
        ! -name 'AGENT.md' ! -name 'AGENTS.md' ! -name 'CLAUDE.md' \
        ! -path "$source_root/scripts/check_roothide.sh" -print > "$source_list"

    failed=0
    while IFS= read -r source_file; do
        if grep -nE '/var/jb|iphoneos-arm64([^e[:alnum:]_-]|$)|THEOS_PACKAGE_SCHEME[[:space:]]*:?=[[:space:]]*rootless|Rootless:[[:space:]]*true' "$source_file"; then
            echo "error: legacy jailbreak layout found in $source_file" >&2
            failed=1
        fi
        case "$source_file" in
            *.c|*.h|*.m|*.mm|*.x|*.sh)
                if grep -niE '((fallback|try|check).*(rootful|standard[- ]rootless|rootless path)|(rootful|standard[- ]rootless|rootless path).*(fallback|try|check))|rootless(Data|Bundle|Group|Dirs)|findRootless|isRootless' "$source_file"; then
                    echo "error: mixed-layout fallback found in $source_file" >&2
                    failed=1
                fi
                ;;
        esac
    done < "$source_list"
    rm -f "$source_list"
    cleanup_path=""

    [ "$failed" -eq 0 ] || fail "RootHide source audit failed"
    echo "RootHide source audit passed."
}

check_staging() {
    staging_root=$(CDPATH= cd -- "$1" && pwd)

    if [ -e "$staging_root/var/jb" ] || [ -e "$staging_root/private/var/jb" ]; then
        fail "stale standard-rootless /var/jb layout is present"
    fi

    require_path "$staging_root" "Applications/ProjectX.app/ProjectX"
    require_path "$staging_root" "Applications/ProjectX.app/LaunchScreen.storyboardc"
    require_path "$staging_root" "Library/MobileSubstrate/DynamicLibraries/ProjectXTweak.dylib"
    require_path "$staging_root" "Library/MobileSubstrate/DynamicLibraries/ProjectXTweak.plist"
    require_path "$staging_root" "Library/MobileSubstrate/DynamicLibraries/ProjectXLoader.dylib"
    require_path "$staging_root" "Library/MobileSubstrate/DynamicLibraries/ProjectXLoader.plist"
    require_path "$staging_root" "Library/WeaponX/WeaponXDaemon"
    require_path "$staging_root" "Library/WeaponX/ProjectXKeychainWorker"
    require_path "$staging_root" "Library/WeaponX/Guardian"
    require_path "$staging_root" "Library/LaunchDaemons/com.hydra.weaponx.guardian.plist"
    require_path "$staging_root" "Library/libSandy/projectx_filesystem_access.plist"
    require_path "$staging_root" "usr/bin/projectx-setup"
    require_path "$staging_root" "usr/bin/weaponx-debug"

    loader_filter="$staging_root/Library/MobileSubstrate/DynamicLibraries/ProjectXLoader.plist"
    payload_filter="$staging_root/Library/MobileSubstrate/DynamicLibraries/ProjectXTweak.plist"
    loader_filter_xml=$(plutil -convert xml1 -o - "$loader_filter") ||
        fail "ProjectXLoader.plist is not a valid plist"
    payload_filter_xml=$(plutil -convert xml1 -o - "$payload_filter") ||
        fail "ProjectXTweak.plist is not a valid plist"
    if ! printf '%s\n' "$loader_filter_xml" | grep -q '<string>com.apple.UIKit</string>' ||
       ! printf '%s\n' "$loader_filter_xml" | grep -q '<string>SpringBoard</string>'; then
        fail "ProjectXLoader.plist must discover UIKit applications and SpringBoard"
    fi
    if printf '%s\n' "$payload_filter_xml" | grep -q '<string>com.apple.UIKit</string>' ||
       printf '%s\n' "$payload_filter_xml" | grep -q '<string>SpringBoard</string>'; then
        fail "ProjectXTweak.plist must not directly target UIKit or SpringBoard"
    fi

    for executable_path in \
        "Applications/ProjectX.app/ProjectX" \
        "Library/MobileSubstrate/DynamicLibraries/ProjectXTweak.dylib" \
        "Library/MobileSubstrate/DynamicLibraries/ProjectXLoader.dylib" \
        "Library/WeaponX/WeaponXDaemon" \
        "Library/WeaponX/ProjectXKeychainWorker" \
        "usr/bin/projectx-setup" \
        "usr/bin/weaponx-debug"; do
        if [ ! -x "$staging_root/$executable_path" ]; then
            fail "required RootHide package executable has the wrong mode: /$executable_path"
        fi
    done

    launchd_plist="$staging_root/Library/LaunchDaemons/com.hydra.weaponx.guardian.plist"
    launchd_program=$(plutil -extract ProgramArguments.0 raw -o - "$launchd_plist")
    if [ "$launchd_program" != "/Library/WeaponX/WeaponXDaemon" ]; then
        fail "LaunchDaemon must use the RootHide logical daemon path"
    fi

    policy="$staging_root/Library/libSandy/projectx_filesystem_access.plist"
    policy_xml=$(plutil -convert xml1 -o - "$policy")
    if ! printf '%s\n' "$policy_xml" | grep -q 'SANDBOX_REDIRECTED_PATH=/rootfs/var/mobile/'; then
        fail "LibSandy policy does not identify real iOS paths through /rootfs"
    fi
    if ! printf '%s\n' "$policy_xml" | grep -q '<string>/var/mobile/Library/WeaponX</string>'; then
        fail "LibSandy policy does not retain the logical RootHide data path"
    fi

    echo "RootHide staging layout passed."
}

check_worker_binary() {
    staging_root=$(CDPATH= cd -- "$1" && pwd)
    worker_path="$staging_root/Library/WeaponX/ProjectXKeychainWorker"
    [ -f "$worker_path" ] && [ -x "$worker_path" ] ||
        fail "staged one-shot Keychain worker is missing or not executable"
    worker_directory=$(dirname -- "$worker_path")
    if [ -e "$worker_directory/.jbroot" ] || [ -L "$worker_directory/.jbroot" ]; then
        fail "the package must not persist a RootHide dependency anchor beside the worker template"
    fi

    lipo_path=${PROJECTX_LIPO:-}
    otool_path=${PROJECTX_OTOOL:-}
    if [ -z "$lipo_path" ]; then
        lipo_path=$(xcrun --find lipo 2>/dev/null || true)
    fi
    if [ -z "$otool_path" ]; then
        otool_path=$(xcrun --find otool 2>/dev/null || true)
    fi
    [ -n "$lipo_path" ] && [ -x "$lipo_path" ] ||
        fail "lipo is required for staged worker architecture validation"
    [ -n "$otool_path" ] && [ -x "$otool_path" ] ||
        fail "otool is required for staged worker dependency validation"

    worker_architectures=$("$lipo_path" -archs "$worker_path")
    for required_architecture in arm64 arm64e; do
        case " $worker_architectures " in
            *" $required_architecture "*) ;;
            *) fail "staged one-shot Keychain worker is missing $required_architecture" ;;
        esac
        dependency_output=$("$otool_path" -arch "$required_architecture" -L "$worker_path")
        dependency_count=$(printf '%s\n' "$dependency_output" |
            grep -Fc '@loader_path/.jbroot/usr/lib/libroothide.dylib' || true)
        if [ "$dependency_count" -ne 1 ]; then
            fail "staged $required_architecture worker must use exactly one RootHide loader anchor"
        fi
    done

    echo "RootHide staged worker dependency audit passed."
}

check_package() {
    package_dir=$(CDPATH= cd -- "$(dirname -- "$1")" && pwd)
    package_path="$package_dir/$(basename -- "$1")"
    [ -f "$package_path" ] || fail "package does not exist: $package_path"

    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/projectx-roothide-package.XXXXXX")
    cleanup_path=$work_dir
    mkdir -p "$work_dir/archive" "$work_dir/control" "$work_dir/data"
    (
        cd "$work_dir/archive"
        ar -x "$package_path"
    )

    set -- "$work_dir/archive"/control.tar.*
    [ "$#" -eq 1 ] && [ -f "$1" ] || fail "package control archive is missing or ambiguous"
    tar -xf "$1" -C "$work_dir/control"
    set -- "$work_dir/archive"/data.tar.*
    [ "$#" -eq 1 ] && [ -f "$1" ] || fail "package data archive is missing or ambiguous"
    tar -xf "$1" -C "$work_dir/data"

    control_file="$work_dir/control/control"
    [ -f "$control_file" ] || fail "package control metadata is missing"
    if ! grep -Eq '^Architecture:[[:space:]]*iphoneos-arm64e[[:space:]]*$' "$control_file"; then
        fail "package architecture is not iphoneos-arm64e"
    fi
    if grep -Eq '^Rootless:[[:space:]]*true[[:space:]]*$' "$control_file"; then
        fail "package retains standard-rootless metadata"
    fi
    for maintainer_script in preinst postinst prerm; do
        if [ ! -x "$work_dir/control/$maintainer_script" ]; then
            fail "required executable maintainer script is missing: $maintainer_script"
        fi
    done

    check_staging "$work_dir/data"
    check_worker_binary "$work_dir/data"

    ldid_path=${PROJECTX_LDID:-}
    if [ -z "$ldid_path" ]; then
        ldid_path=$(command -v ldid || true)
    fi
    [ -n "$ldid_path" ] && [ -x "$ldid_path" ] || fail "ldid is required for package entitlement validation"
    mkdir -p "$work_dir/entitlements"
    for entitlement_target in \
        "Applications/ProjectX.app/ProjectX|ProjectX.entitlements" \
        "Library/MobileSubstrate/DynamicLibraries/ProjectXTweak.dylib|ent.plist" \
        "Library/MobileSubstrate/DynamicLibraries/ProjectXLoader.dylib|ent.plist" \
        "Library/WeaponX/WeaponXDaemon|ent.plist" \
        "Library/WeaponX/ProjectXKeychainWorker|KeychainWorkerTemplate.entitlements"; do
        binary_path=${entitlement_target%%|*}
        expected_name=${entitlement_target#*|}
        target_name=$(basename -- "$binary_path")
        extracted_plist="$work_dir/entitlements/$target_name.plist"
        extracted_binary="$work_dir/entitlements/$target_name.actual"
        expected_binary="$work_dir/entitlements/$target_name.expected"
        if ! "$ldid_path" -e "$work_dir/data/$binary_path" > "$extracted_plist"; then
            fail "could not extract entitlements from /$binary_path"
        fi
        if ! plutil -convert binary1 -o "$extracted_binary" "$extracted_plist"; then
            fail "invalid extracted entitlements for /$binary_path"
        fi
        if ! plutil -convert binary1 -o "$expected_binary" "$project_root/$expected_name"; then
            fail "invalid entitlement contract: $expected_name"
        fi
        if ! cmp -s "$extracted_binary" "$expected_binary"; then
            fail "signature entitlements for /$binary_path do not match $expected_name"
        fi
    done

    rm -rf "$work_dir"
    cleanup_path=""
    echo "RootHide package audit passed: $package_path"
}

case "${1:-}" in
    --audit-source)
        [ "$#" -eq 2 ] || fail "usage: $0 --audit-source PROJECT_ROOT"
        check_source "$2"
        ;;
    --check-staging)
        [ "$#" -eq 2 ] || fail "usage: $0 --check-staging STAGING_ROOT"
        check_staging "$2"
        ;;
    --check-worker-binary)
        [ "$#" -eq 2 ] || fail "usage: $0 --check-worker-binary STAGING_ROOT"
        check_worker_binary "$2"
        ;;
    --check-package)
        [ "$#" -eq 2 ] || fail "usage: $0 --check-package PACKAGE.deb"
        check_package "$2"
        ;;
    *)
        fail "usage: $0 {--audit-source PROJECT_ROOT|--check-staging STAGING_ROOT|--check-worker-binary STAGING_ROOT|--check-package PACKAGE.deb}"
        ;;
esac
