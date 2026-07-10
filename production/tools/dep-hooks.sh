#!/bin/bash
# dep-hooks.sh - shell function overrides that log file-staging
# operations to a JSONL trace file.
#
# Source this from a recipe that wants to track which source files end
# up where (rpm packaging, docker image building, install scripts, ...):
#
#     export DEP_TREE=yes
#     export DEP_TRACK_FILE=/path/to/trace.jsonl
#     . $(ADMIN_DIR)/tools/dep-hooks.sh
#     cp foo.so /staging/foo.so       # logged as {type:"cp", sources:[realpath], dest:realpath}
#     install -m 0755 bar /staging/   # logged as {type:"install", ...}
#     dep_add /some/other/file        # manual dep entry
#
# When DEP_TREE != "yes" the hooks are no-ops -- safe to source
# unconditionally.
#
# Lifted from the reference tools tree and adapted.
#
# Path canonicalisation policy: `realpath -s` (absolute, but symlinks
# left in place).  Design intent: emit is fast + minimal, and OUT_DIR
# views (like `build/lib/rhlinux/debug/libt2.so ->
# build/example/t2/rhlinux/debug/libt2.so`) stay literal in the trace.
# Final canonicalisation to real disk paths happens at
# **aggregation/load time** in `production/tools/pydep/dag.py`, so
# every consumer of the dep-graph sees the same realpath'd view
# without paying the cost inside every build recipe.

_dep_track_log() {
    [ -z "$DEP_TRACK_FILE" ] && return 0

    local op_type="$1"; shift
    # `${@: -1}` picks the last positional as a single element; assigning
    # to a string is safe here because we know it's exactly one entry,
    # but shellcheck can't prove it (SC2124).  Take the last arg into a
    # 1-element array first, then dereference [0] -- same result, no
    # warning, and future-proof if the calling convention changes.
    local -a _last=("${@: -1}")
    local dest="${_last[0]}"
    local sources=("${@:1:$#-1}")

    if [ -e "$dest" ] || [ -L "$dest" ]; then
        dest=$(realpath -s "$dest" 2>/dev/null || echo "$dest")
    fi

    local json_sources="[" first=true
    for src in "${sources[@]}"; do
        if [ -e "$src" ] || [ -L "$src" ]; then
            src=$(realpath -s "$src" 2>/dev/null || echo "$src")
        fi
        if [ "$first" = true ]; then
            json_sources+="\"$src\""; first=false
        else
            json_sources+=",\"$src\""
        fi
    done
    json_sources+="]"

    # de-duplicate exact (sources, dest) pairs
    if [ -f "$DEP_TRACK_FILE" ] && \
       grep -qF "\"sources\":$json_sources,\"dest\":\"$dest\"" "$DEP_TRACK_FILE" 2>/dev/null; then
        return 0
    fi

    echo "{\"type\":\"$op_type\",\"sources\":$json_sources,\"dest\":\"$dest\"}" >> "$DEP_TRACK_FILE"
}

# Public API: add an explicit dep with no copy
dep_add() {
    [ $# -eq 0 ] && { echo "Usage: dep_add <file> [...]" >&2; return 1; }
    [ -z "$DEP_TRACK_FILE" ] && return 0

    local json_sources="[" first=true
    for src in "$@"; do
        if [ -e "$src" ] || [ -L "$src" ]; then
            src=$(realpath -s "$src" 2>/dev/null || echo "$src")
        fi
        if [ "$first" = true ]; then
            json_sources+="\"$src\""; first=false
        else
            json_sources+=",\"$src\""
        fi
    done
    json_sources+="]"

    echo "{\"type\":\"manual\",\"sources\":$json_sources,\"dest\":\"\"}" >> "$DEP_TRACK_FILE"
}

# Override: cp
cp() {
    local all_files=() skip=false a
    for a in "$@"; do
        [ "$skip" = true ] && skip=false && continue
        case "$a" in
            -t|--target-directory|--suffix|--backup) skip=true ;;
            -*) ;;
            *) all_files+=("$a") ;;
        esac
    done
    if [ "${#all_files[@]}" -gt 1 ] && [ -n "$DEP_TRACK_FILE" ]; then
        local dest="${all_files[-1]}"
        unset 'all_files[-1]'
        _dep_track_log "cp" "${all_files[@]}" "$dest"
    fi
    command cp "$@"
}

# Override: install
install() {
    local all_files=() a
    for a in "$@"; do
        [[ ! "$a" =~ ^- ]] && all_files+=("$a")
    done
    if [ "${#all_files[@]}" -ge 2 ] && [ -n "$DEP_TRACK_FILE" ]; then
        local dest="${all_files[-1]}"
        unset 'all_files[-1]'
        _dep_track_log "install" "${all_files[@]}" "$dest"
    fi
    command install "$@"
}

if [ "$DEP_TREE" = "yes" ]; then
    export DEP_TRACK_FILE="${DEP_TRACK_FILE:-dep_track_$$.jsonl}"
    mkdir -p "$(dirname "$DEP_TRACK_FILE")" 2>/dev/null || true
    [ ! -f "$DEP_TRACK_FILE" ] && \
        echo "{\"session\":\"init\",\"pid\":$$,\"timestamp\":\"$(date -Iseconds)\"}" > "$DEP_TRACK_FILE"
    export -f cp install dep_add _dep_track_log
fi
