#!/bin/bash

# Library dependency finder
# Usage: getdeps.sh [--filter path1:path2:...] link_flags...

set -euo pipefail

FILTER_PATHS=""
if [[ $# -gt 0 && "$1" == "--filter" ]]; then
    FILTER_PATHS="$2"
    shift 2
fi

findLibs() {
    for lib in $LIBS; do
        for libpath in $LIBPATHS; do
            if ls "$libpath/lib$lib.so"* &>/dev/null || [[ -s "$libpath/lib$lib.a" ]]; then
                if ls "$libpath/lib$lib.so"* &>/dev/null; then
                    find "$libpath" -name "lib$lib.so*" -type f | head -1
                else
                    echo "$libpath/lib$lib.a"
                fi
                break
            fi
        done
    done
}

PARAMETERS=$(echo "$*" | tr ' ' '\n')
if [[ -n "$FILTER_PATHS" ]]; then
    LIBPATHS=$(echo "$FILTER_PATHS" | tr ':' ' ')
else
    LIBPATHS=$(echo "$PARAMETERS" | sed -n 's/^-L//p')
fi

LIBS=$(echo "$PARAMETERS" | sed -n 's/^-l//p')
findLibs
