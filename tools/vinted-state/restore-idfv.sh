#!/bin/sh
# Run in the RootHide bootstrap as mobile, after sudo credentials are authorized.
set -eu
if [ "$#" -ne 4 ]; then
    echo "usage: $0 HELPER PHYSICAL_LSD_PLIST EXPECTED_UUID REPLACEMENT_UUID" >&2
    exit 2
fi
helper=$1
plist=$2
expected=$3
replacement=$4
case "$helper" in /*) ;; *) echo 'helper must be an absolute path' >&2; exit 2;; esac
if [ ! -x "$helper" ]; then echo 'helper missing' >&2; exit 2; fi
sudo -n true
pid=$(launchctl print user/501/com.apple.lsd | while read key equal value rest; do
    if [ "$key" = pid ] && [ "$equal" = = ]; then echo "$value"; fi
done)
case "$pid" in ''|*[!0-9]*) echo 'invalid user lsd pid' >&2; exit 1;; esac
kill -STOP "$pid"
trap 'kill -CONT "$pid" 2>/dev/null || true' EXIT HUP INT TERM
sudo -n "$helper" set "$plist" "$expected" "$replacement"
kill -KILL "$pid"
trap - EXIT HUP INT TERM
"$helper"
