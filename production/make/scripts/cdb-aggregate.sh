#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# cdb-aggregate.sh -- fold *.cc.json fragments into compile_commands.json.
#
# Usage: cdb-aggregate.sh <gm-out-dir> <output-json> <symlink-path> [proj-top]
#
# Idle-fast: exits early when the DB is newer than every fragment, so a
# no-op `make` doesn't rescan the tree.  Empty tree yields a `[]` DB.
#
# Also merges vendor-provided compile DBs from third_party/**/
# compile_commands.json (produced by `bear -- make` or CMake's
# CMAKE_EXPORT_COMPILE_COMMANDS=ON).  Entries are deduped by `file`;
# last-wins on collision.

set -eu

gm_out=$1
out=$2
lnk=$3
proj_top=${4:-.}

# Vendor CDBs to fold in (source-integrated 3rd party emitting its
# own compile_commands.json).  Missing = fine; find is quiet.
vendor_cdbs=$(find "$proj_top/third_party" -maxdepth 4 \
              -name 'compile_commands.json' 2>/dev/null || true)

if [ -f "$out" ]; then
    # Skip when DB is newer than every fragment AND every vendor CDB.
    newer_frag=$(find "$gm_out" -name '*.cc.json' -newer "$out" -print -quit 2>/dev/null || true)
    newer_vend=""
    for v in $vendor_cdbs ; do
        [ "$v" -nt "$out" ] && { newer_vend=1 ; break ; }
    done
    [ -z "$newer_frag" ] && [ -z "$newer_vend" ] && exit 0
fi

mkdir -p "$(dirname "$out")"

# Concat gm fragments (each = one JSON object) + every vendor CDB
# (each = a JSON array).  jq flattens the array-of-arrays back into
# a flat list; final `group_by / last` de-dupes by `file` field so
# a vendor CDB that shadows a gm entry wins (later-loaded).
{
    find "$gm_out" -name '*.cc.json' -print0 2>/dev/null \
        | xargs -0 -r cat
    for v in $vendor_cdbs ; do
        cat "$v"
    done
} | jq -s '[.[] | if type == "array" then .[] else . end]
           | group_by(.file) | map(.[-1])' \
    > "$out.tmp" 2>/dev/null && mv "$out.tmp" "$out" || echo '[]' > "$out"

ln -sfn "$out" "$lnk"

n_gm=$(find "$gm_out" -name '*.cc.json' 2>/dev/null | wc -l)
n_vend=0
for v in $vendor_cdbs ; do
    m=$(jq 'length' < "$v" 2>/dev/null || echo 0)
    n_vend=$((n_vend + m))
done
n_total=$(jq 'length' < "$out")
if [ "$n_vend" -gt 0 ] ; then
    printf '  CDB     %s  (%s entries: %s gm + %s vendor)\n' \
        "$out" "$n_total" "$n_gm" "$n_vend"
else
    printf '  CDB     %s  (%s entries)\n' "$out" "$n_total"
fi
