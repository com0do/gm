#!/bin/bash
# Sample post-install hook for pkg-p2.  Staged with mode 0755 via the
# per-file XML attributes on the Config_OS Filegroup entry.

set -e
echo "p2: post-install ran on $(hostname) at $(date -Iseconds)"
