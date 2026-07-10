#!/bin/sh
# i1 entrypoint -- runs the t3 binary packaged from the gm tree.
set -e

echo "--- gm/example/i1 container starting ---"
cat /etc/p1/p1.conf 2>/dev/null || true
echo "---"
exec /usr/bin/t3 "$@"
