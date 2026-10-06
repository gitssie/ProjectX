#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
/bin/sh "$root/tools/app-state/build.sh" test
output=$(mktemp -d "${TMPDIR:-/tmp}/px-app-state-service-tests.XXXXXX")
trap 'rm -rf "$output"' EXIT HUP INT TERM
xcrun --sdk macosx clang -fobjc-arc -Werror -DPROJECTX_PATHS_TESTING=1 -I"$root" \
    "$root/PXAppStateServiceTests.m" "$root/PXAppStateService.m" \
    "$root/PXKeychainOneShotExecution.m" "$root/PXKeychainOneShot.m" \
    "$root/KeychainCommand.m" "$root/AppIdentity.m" "$root/PXRootHidePath.m" \
    "$root/tools/app-state/core/PXAppState.m" "$root/tools/app-state/adapters/PXASNative.m" \
    -framework Foundation -framework Security -framework LocalAuthentication -o "$output/service-tests"
"$output/service-tests"
xcrun --sdk macosx clang -fobjc-arc -Werror -DPROJECTX_PATHS_TESTING=1 -I"$root" \
    "$root/PXRootHidePathTests.m" "$root/PXRootHidePath.m" -framework Foundation -o "$output/path-tests"
"$output/path-tests"
