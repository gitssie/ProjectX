#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$project_root/.deploy" "$project_root/.deploy/tmp"
chmod 700 "$project_root/.deploy" "$project_root/.deploy/tmp"
test_directory=$(mktemp -d "$project_root/.deploy/tmp/geo-ip-location-tests.XXXXXX")
trap 'rm -rf "$test_directory"' EXIT HUP INT TERM

xcrun --sdk macosx clang \
    -fobjc-arc \
    -fblocks \
    -Werror \
    -I"$project_root" \
    "$project_root/PXGeoIPLocationTests.m" \
    "$project_root/PXGeoIPLocation.m" \
    -framework Foundation \
    -o "$test_directory/PXGeoIPLocationTests"

"$test_directory/PXGeoIPLocationTests"

echo "GEO IP location regression tests passed."
