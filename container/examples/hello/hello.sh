#!/bin/sh
echo "--- container/examples/hello ---"
echo "image:    hello:1.0.0"
echo "msg:      hello from container"
exec "$@"
