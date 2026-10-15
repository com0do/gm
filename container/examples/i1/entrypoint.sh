#!/bin/sh
# i1 entrypoint -- runs tmctl, packaged from the gm tree (pkg-tm-tools).
set -e

echo "--- gm/example/i1 container starting ---"
[ $# -gt 0 ] || set -- version
exec /usr/bin/tmctl "$@"
