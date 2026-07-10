#!/bin/bash
#
# depcxx.sh - resolve `-lXXX` link arguments to absolute library paths.
#
# Walks every `-L<dir>` in the input args (or the `--filter` paths) and
# for each `-l<name>` emits the absolute path of the first matching
# lib<name>.so* / lib<name>.a it finds.  Used by target.c.mk's
# DEP_TREE=yes machinery to feed the linked-library set into jq when
# aggregating per-target .link.dep.json files.
#
# Usage:
#   depcxx.sh [--filter path1:path2:...] <link flags ...>

set -euo pipefail

FILTER_PATHS=""
if [[ $# -gt 0 && "$1" == "--filter" ]]; then
    FILTER_PATHS="$2"
    shift 2
fi

PARAMETERS=$(echo "$*" | tr ' ' '\n')
if [[ -n "$FILTER_PATHS" ]]; then
    LIBPATHS=$(echo "$FILTER_PATHS" | tr ':' ' ')
else
    LIBPATHS=$(echo "$PARAMETERS" | sed -n 's/^-L//p')
fi
LIBS=$(echo "$PARAMETERS" | sed -n 's/^-l//p')

for lib in $LIBS; do
    for libpath in $LIBPATHS; do
        # -follow / -L so we accept the OUT_DIR symlinks the link step
        # creates pointing at the real .so / .a artifacts.  Paths are
        # emitted as-is (OUT_DIR-view or BUILD_DIR, whichever `find`
        # returns first); final `readlink -f` canonicalisation lives
        # at load time in pydep/dag.py.
        if ls "$libpath/lib$lib.so"* &>/dev/null; then
            { find -L "$libpath" -maxdepth 1 -name "lib$lib.so*" 2>/dev/null || true; } | head -1
            break
        elif [[ -e "$libpath/lib$lib.a" ]]; then
            echo "$libpath/lib$lib.a"
            break
        fi
    done
done
