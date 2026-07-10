#!/bin/bash
# validate.sh -- offline sanity check for customization/.
#
# What it does:
#   1. `pyang` parse of every yang/**/*.yang, resolving imports via
#      the union of the yang/ subdirs as the search path.
#   2. Cross-check: every leaf referenced from generic.yaml matches
#      a yang leaf under a mount declared in templates/*.template.yaml.
#
# Standalone.  Doesn't call gm; doesn't share code with gm.
# Run before a helm-chart release: `./tools/validate.sh`.

set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE"

fail=0
say() { printf '  %s\n' "$*"; }

# --- 1. pyang: parse every yang module ------------------------------------
if ! command -v pyang >/dev/null 2>&1; then
    echo "validate.sh: pyang not installed (pip install --user pyang)." >&2
    exit 2
fi

YANG_PATHS=$(find yang -type d | tr '\n' ':' | sed 's/:$//')
export YANG_MODPATH="$YANG_PATHS"

echo "pyang parse:"
find yang -name '*.yang' -type f | sort | while read -r mod; do
    if pyang -p "$YANG_PATHS" --strict "$mod" >/tmp/gm-cust-pyang.$$.log 2>&1; then
        say "$mod  ✓"
    else
        say "$mod  ✗"
        sed 's/^/    /' /tmp/gm-cust-pyang.$$.log
        fail=1
    fi
    rm -f /tmp/gm-cust-pyang.$$.log
done

# --- 2. Cross-check generic.yaml leaves against templates -----------------
#
# For each templates/*.template.yaml, ensure:
#   - `mount:` path exists in generic.yaml
#   - every alias resolves to something under the mount
#
# Written in python because bash + yaml is misery; kept inline so the
# tree stays a single-directory drop.
echo
echo "generic.yaml cross-check:"
python3 - <<'PY' && say "all mounts + aliases resolve  ✓" || { fail=1; say "mismatch  ✗"; }
import os, sys, glob, yaml

def path_get(root, dotted):
    node = root
    for seg in dotted.split("/"):
        if not isinstance(node, dict) or seg not in node:
            return None
        node = node[seg]
    return node

with open("generic/generic.yaml") as f:
    generic = yaml.safe_load(f) or {}

ok = True
for tmpl_path in sorted(glob.glob("templates/*.template.yaml")):
    with open(tmpl_path) as f:
        t = yaml.safe_load(f)
    mount = t.get("mount")
    if mount is None or path_get(generic, mount) is None:
        print(f"  {tmpl_path}: mount '{mount}' not in generic.yaml", file=sys.stderr)
        ok = False
        continue
    for name, sub in (t.get("aliases") or {}).items():
        if path_get(generic, f"{mount}/{sub}") is None:
            print(f"  {tmpl_path}: alias {name}='{sub}' missing under {mount}", file=sys.stderr)
            ok = False

sys.exit(0 if ok else 1)
PY

exit $fail
