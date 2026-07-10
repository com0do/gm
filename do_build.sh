#!/bin/bash
# Quick smoke build: wipe the output tree, build t3, run it.
#
# t3 is an exe -- with the type-based output layout it lands under
# $(GM_EXEC_DIR) = $(GM_OUT)/exec/<arch>/<mode>/, not lib/.

set -e
cd "$(dirname "$0")"

make distclean
make t3
./build/exec/rhlinux/debug/t3
