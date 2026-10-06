#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
umask 077
mkdir -p "$root/build"
for tool in LSIDFVCheck KeychainCheck VintedInspect VintedBackup VintedBaseline VintedFinalize VintedRestore RestoreVerify; do
    xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 \
        -fobjc-arc -Wall -Wextra -Werror "$root/src/$tool.m" \
        -framework Foundation -framework Security -framework LocalAuthentication \
        -o "$root/build/$tool"
done
printf '%s\n' 'Built 8 unsigned device helpers. No deployment performed.'
