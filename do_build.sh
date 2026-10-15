#!/bin/bash
# Quick smoke build: wipe the output tree, build the daemon, run it.
#
# tmd is an exe -- with the type-based output layout it lands under
# $(GM_EXEC_DIR) = $(GM_OUT)/exec/<arch>/<mode>/, not lib/.

set -e
cd "$(dirname "$0")"

make distclean
make tmd loadgen
./build/exec/rhlinux/debug/tmd --version
./build/exec/rhlinux/debug/loadgen cpu.load 0.5 200 |
    ./build/exec/rhlinux/debug/tmd --config example/daemon/deploy/tmd.conf
