#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
umask 077
mkdir -p "$root/build"
case "${1:-test}" in
    test)
        xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror \
            "$root/core/PXAppState.m" "$root/tests/PXASFixture.m" "$root/tests/StateTests.m" \
            -framework Foundation -o "$root/build/state-tests"
        "$root/build/state-tests"
        xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror \
            "$root/core/PXAppState.m" "$root/adapters/PXASNative.m" "$root/tests/NativeKeychainTests.m" \
            -framework Foundation -framework Security -framework LocalAuthentication -o "$root/build/native-keychain-tests"
        "$root/build/native-keychain-tests"
        xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror \
            "$root/core/PXAppStateSession.m" "$root/tests/SessionTests.m" \
            -framework Foundation -o "$root/build/session-tests"
        "$root/build/session-tests"
        ;;
    ios)
        xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 \
            -fobjc-arc -Wall -Wextra -Werror "$root/core/PXAppState.m" \
            "$root/adapters/PXASNative.m" "$root/cli/main.m" \
            -framework Foundation -framework Security -framework LocalAuthentication \
            -o "$root/build/app-state"
        xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 \
            -fobjc-arc -Wall -Wextra -Werror "$root/cli/VendorWorker.m" \
            -framework Foundation -o "$root/build/vendor-worker"
        echo 'Built unsigned iOS tools; no deployment performed.'
        ;;
    *) echo "usage: $0 test|ios" >&2; exit 2;;
esac
