#!/bin/sh

set -eu

TWEAK_DIR="/Library/MobileSubstrate/DynamicLibraries"
APP_DIR="/Applications/ProjectX.app"
UICACHE="/usr/bin/uicache"
SBRELOAD="/usr/bin/sbreload"

echo "Setting up ProjectX for RootHide..."

mkdir -p "$TWEAK_DIR"
chmod 755 "/Library/MobileSubstrate" "$TWEAK_DIR"

for tweak_file in ProjectXTweak.dylib ProjectXTweak.plist; do
    if [ -f "$TWEAK_DIR/$tweak_file" ]; then
        chmod 644 "$TWEAK_DIR/$tweak_file"
    fi
done

if [ ! -x "$APP_DIR/ProjectX" ]; then
    echo "error: ProjectX executable not found at $APP_DIR/ProjectX" >&2
    exit 1
fi
chmod 755 "$APP_DIR" "$APP_DIR/ProjectX"

if [ ! -x "$UICACHE" ]; then
    echo "error: RootHide uicache not found at $UICACHE" >&2
    exit 1
fi
"$UICACHE" --path "$APP_DIR"

if [ ! -x "$SBRELOAD" ]; then
    echo "error: RootHide sbreload not found at $SBRELOAD" >&2
    exit 1
fi
"$SBRELOAD"

echo "ProjectX RootHide setup complete."
