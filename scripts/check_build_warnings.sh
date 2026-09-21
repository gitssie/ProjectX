#!/bin/sh

set -eu

check_launch_screen() {
    app_path=$1
    compiled_path="$app_path/LaunchScreen.storyboardc"
    raw_path="$app_path/LaunchScreen.storyboard"

    if [ ! -d "$compiled_path" ]; then
        echo "error: compiled LaunchScreen.storyboardc is missing from $app_path" >&2
        return 1
    fi
    if [ -z "$(ls -A "$compiled_path")" ]; then
        echo "error: compiled LaunchScreen.storyboardc is empty in $app_path" >&2
        return 1
    fi
    if [ -e "$raw_path" ]; then
        echo "error: raw LaunchScreen.storyboard was packaged instead of compiled output" >&2
        return 1
    fi
}

if [ "${1:-}" = "--check-launch-screen" ]; then
    if [ "$#" -ne 2 ]; then
        echo "usage: $0 --check-launch-screen APP_PATH" >&2
        exit 2
    fi
    check_launch_screen "$2"
    exit 0
fi

if [ "$#" -ne 0 ]; then
    echo "usage: $0 [--check-launch-screen APP_PATH]" >&2
    exit 2
fi

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_log=$(mktemp "${TMPDIR:-/tmp}/projectx-build.XXXXXX.log")
trap 'rm -f "$build_log"' EXIT HUP INT TERM

/bin/sh "$project_root/scripts/check_roothide.sh" --audit-source "$project_root"

if ! (
    cd "$project_root"
    /usr/bin/make clean && /usr/bin/make -j1 package FINALPACKAGE=1
) >"$build_log" 2>&1; then
    cat "$build_log"
    echo "error: default ProjectX package build failed" >&2
    exit 1
fi

cat "$build_log"
diagnostics=$(grep -En '(^|[[:space:]])warning:' "$build_log" || true)
ibtool_diagnostics=$(awk '
    /<key>com\.apple\.ibtool\.document\.(errors|warnings)<\/key>/ {
        diagnostic_line = NR ":" $0
        if (getline <= 0 || $0 !~ /^[[:space:]]*<dict\/>[[:space:]]*$/) {
            print diagnostic_line
            if ($0 != "") {
                print NR ":" $0
            }
        }
    }
' "$build_log")
if [ -n "$diagnostics$ibtool_diagnostics" ]; then
    echo "$diagnostics" >&2
    echo "$ibtool_diagnostics" >&2
    echo "error: compiler, linker, or Interface Builder warnings were detected" >&2
    exit 1
fi

echo "ProjectX warning gate passed."
