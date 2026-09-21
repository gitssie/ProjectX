#!/bin/sh

set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 STAGED_KEYCHAIN_WORKER" >&2
    exit 2
fi

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
worker_directory=$(CDPATH= cd -- "$(dirname -- "$1")" && pwd)
staged_worker="$worker_directory/$(basename -- "$1")"
case "$staged_worker" in
    "$project_root"/.theos/_/Library/WeaponX/ProjectXKeychainWorker) ;;
    *)
        echo "error: staged worker must come from the current ProjectX staging tree" >&2
        exit 1
        ;;
esac
if [ ! -f "$staged_worker" ] || [ ! -x "$staged_worker" ]; then
    echo "error: real staged one-shot Keychain worker is missing or not executable" >&2
    exit 1
fi

mkdir -p "$project_root/.deploy" "$project_root/.deploy/tmp"
chmod 700 "$project_root/.deploy" "$project_root/.deploy/tmp"
test_directory=$(mktemp -d "$project_root/.deploy/tmp/keychain-one-shot-tests.XXXXXX")
trap 'rm -rf "$test_directory"' EXIT HUP INT TERM

xcrun --sdk macosx clang \
    -fobjc-arc \
    -fblocks \
    -Werror \
    -DPROJECTX_PATHS_TESTING=1 \
    -I"$project_root" \
    "$project_root/PXKeychainOneShotExecutionTests.m" \
    "$project_root/PXKeychainOneShotExecution.m" \
    "$project_root/PXKeychainOneShot.m" \
    "$project_root/KeychainCommand.m" \
    "$project_root/AppIdentity.m" \
    "$project_root/PXRootHidePath.m" \
    -framework Foundation \
    -framework Security \
    -o "$test_directory/PXKeychainOneShotExecutionTests"

PROJECTX_STAGED_KEYCHAIN_WORKER="$staged_worker" \
    "$test_directory/PXKeychainOneShotExecutionTests"

echo "One-shot Keychain staged-layout regression tests passed."
