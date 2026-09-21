#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$project_root/.deploy" "$project_root/.deploy/tmp"
chmod 700 "$project_root/.deploy" "$project_root/.deploy/tmp"
test_directory=$(mktemp -d "$project_root/.deploy/tmp/process-hook-policy-tests.XXXXXX")
trap 'rm -rf "$test_directory"' EXIT HUP INT TERM

xcrun --sdk macosx clang \
    -fobjc-arc \
    -Werror \
    -I"$project_root" \
    "$project_root/PXProcessHookPolicyTests.m" \
    "$project_root/PXProcessHookPolicy.m" \
    -framework Foundation \
    -o "$test_directory/PXProcessHookPolicyTests"

"$test_directory/PXProcessHookPolicyTests"

xcrun --sdk macosx clang \
    -fobjc-arc \
    -fblocks \
    -Werror \
    -I"$project_root" \
    "$project_root/ProjectXLoaderPolicyTests.m" \
    "$project_root/ProjectXLoaderPolicy.m" \
    -framework Foundation \
    -o "$test_directory/ProjectXLoaderPolicyTests"

"$test_directory/ProjectXLoaderPolicyTests"

application_hook_files="
RegionEnvironmentHooks.x
AppContainerHooks.x
AppGroupHooks.x
CanvasFingerprintHooks.x
PasteboardHooks.x
BootTimeHooks.x
DeviceModelHooks.x
DeviceSpecHooks.x
AppInstallHooks.x
OpenGLHooks.x
UUIDHooks.x
DomainBlockingHooks.x
WiFiHook.x
StorageHooks.x
BatteryHooks.x
NetworkConnectionTypeHooks.x
SensorHooks.x
UberURLHooks.x
ThemeHooks.x
IOSVersionHooks.x
VPNDetectionBypass.x
"
for source_file in $application_hook_files; do
    if ! grep -q 'PXCurrentProcessMayInstallApplicationHooks' "$project_root/$source_file"; then
        echo "error: missing process hook policy gate in $source_file" >&2
        exit 1
    fi
done

logos_preprocessor=$(command -v logos.pl || true)
if [ -z "$logos_preprocessor" ] || [ ! -x "$logos_preprocessor" ]; then
    echo "error: logos.pl is required to verify generated hook constructors" >&2
    exit 1
fi
for source_file in $application_hook_files; do
    generated_source="$test_directory/${source_file}.mm"
    "$logos_preprocessor" "$project_root/$source_file" > "$generated_source"
    constructor_count=$(grep -c '__attribute__((constructor))' "$generated_source" || true)
    if [ "$constructor_count" -ne 1 ]; then
        echo "error: $source_file generated $constructor_count constructors; expected exactly one guarded constructor" >&2
        exit 1
    fi
done

if ! grep -q 'hookScope == PXProcessHookScopeSpringBoard' "$project_root/Tweak.x"; then
    echo "error: Tweak.x is missing the SpringBoard-only hook path" >&2
    exit 1
fi
if ! grep -q 'hookScope == PXProcessHookScopeNone' "$project_root/Tweak.x"; then
    echo "error: Tweak.x is missing the fail-closed process hook path" >&2
    exit 1
fi
if ! grep -q 'PXCurrentProcessMayInstallApplicationHooks' "$project_root/Tweak.x"; then
    echo "error: Tweak.x does not require an explicitly selected application" >&2
    exit 1
fi

if grep -q 'com.apple.UIKit' "$project_root/ProjectXTweak.plist"; then
    echo "error: full ProjectXTweak payload still targets every UIKit process" >&2
    exit 1
fi
if ! grep -q 'com.apple.UIKit' "$project_root/ProjectXLoader.plist"; then
    echo "error: lightweight loader is missing the UIKit discovery filter" >&2
    exit 1
fi
getifaddrs_owners=$(grep -l 'EKHook.*getifaddrs\|MSHookFunction.*getifaddrs\|dlsym.*getifaddrs' \
    "$project_root"/*.m "$project_root"/*.x | wc -l | tr -d ' ')
if [ "$getifaddrs_owners" -ne 1 ]; then
    echo "error: expected one getifaddrs owner, found $getifaddrs_owners" >&2
    exit 1
fi
cncopy_owners=$(grep -l 'EKHook.*CNCopyCurrentNetworkInfo\|replaced_CNCopyCurrentNetworkInfo' \
    "$project_root"/*.x | wc -l | tr -d ' ')
if [ "$cncopy_owners" -ne 1 ]; then
    echo "error: expected one CNCopyCurrentNetworkInfo owner, found $cncopy_owners" >&2
    exit 1
fi
sysctlbyname_installers=$(grep -l 'EKHook.*sysctlbyname\|MSHookFunction.*sysctlbyname\|dlsym.*sysctlbyname' \
    "$project_root"/*.m "$project_root"/*.x | wc -l | tr -d ' ')
if [ "$sysctlbyname_installers" -ne 1 ] || \
   ! grep -q 'EKHook.*sysctlbyname\|MSHookFunction.*sysctlbyname\|dlsym.*sysctlbyname' \
       "$project_root/PXSysctlHookRouter.m"; then
    echo "error: sysctlbyname must be installed only by PXSysctlHookRouter.m" >&2
    exit 1
fi
if grep -q 'hw.cpubrand.*hw.model' "$project_root/DeviceSpecHooks.x"; then
    echo "error: DeviceSpecHooks still maps hw.model to the CPU marketing name" >&2
    exit 1
fi
if grep -q '%init(SensorSpoofing)' "$project_root/Tweak.x"; then
    echo "error: immutable legacy CoreMotion mutation hooks are still initialized" >&2
    exit 1
fi
if grep -q 'CFRunLoopRun' "$project_root/SensorHooks.x"; then
    echo "error: sensor hooks create a non-terminating worker run loop" >&2
    exit 1
fi
if grep -q 'instanceMethodSignatureForSelector:@selector(description)' "$project_root/SensorHooks.x"; then
    echo "error: sensor proxies fabricate method signatures for unknown selectors" >&2
    exit 1
fi

for notification_name in \
    com.hydra.projectx.appIdentityChanged \
    com.hydra.projectx.profileChanged \
    com.hydra.projectx.profileGenerationChanged
do
    if ! grep -q "$notification_name" "$project_root/AppIdentityHookSupport.m"; then
        echo "error: app identity mappings do not observe $notification_name" >&2
        exit 1
    fi
done
if ! grep -q 'PXAppIdentityBootstrapDepth > 0' "$project_root/AppIdentityHookSupport.m" ||
   ! grep -q 'PXProfileMappingChangedCallback' "$project_root/AppIdentityHookSupport.m"; then
    echo "error: local identity bootstrap and external profile changes are not isolated" >&2
    exit 1
fi

for source_file in AppContainerHooks.x AppGroupHooks.x AppInstallHooks.x; do
    observer_line=$(grep -n 'PXObserveAppIdentityMappingChanges' "$project_root/$source_file" | tail -n 1 | cut -d: -f1)
    prepare_line=$(grep -n 'PXPrepareCurrentProcessAppIdentity' "$project_root/$source_file" | tail -n 1 | cut -d: -f1)
    if [ -z "$observer_line" ] || [ -z "$prepare_line" ] || [ "$observer_line" -ge "$prepare_line" ]; then
        echo "error: $source_file must observe profile changes before preparing identity mappings" >&2
        exit 1
    fi
done

if grep -q 'isApplicationEnabled:currentBundleID' "$project_root/DeviceModelHooks.x"; then
    echo "error: DeviceModelHooks excludes selected app extensions" >&2
    exit 1
fi

for grouped_hook in \
    'PasteboardHooks.x:PXScopedPasteboardHooks' \
    'DeviceModelHooks.x:PXScopedDeviceModelHooks'
do
    source_file=${grouped_hook%%:*}
    group_name=${grouped_hook#*:}
    source_path="$project_root/$source_file"
    if ! grep -q "%group $group_name" "$source_path"; then
        echo "error: $source_file leaves Logos hooks outside $group_name" >&2
        exit 1
    fi
    gate_line=$(grep -n 'PXCurrentProcessMayInstallApplicationHooks' "$source_path" | head -n 1 | cut -d: -f1)
    init_line=$(grep -n "%init($group_name)" "$source_path" | head -n 1 | cut -d: -f1)
    if [ -z "$gate_line" ] || [ -z "$init_line" ] || [ "$gate_line" -ge "$init_line" ]; then
        echo "error: $source_file initializes $group_name before its selected-target gate" >&2
        exit 1
    fi
done

echo "Process hook policy regression tests passed."
