#!/bin/bash
#
# depgo.sh - emit a {file, deps} JSON for one Go binary.
#
# Walks `go list -deps -f '{{.ImportPath}}'` to find every internal
# package the binary transitively imports, then `go list -f
# '{{.Dir}} {{.GoFiles}}'` to expand each package to absolute source
# file paths.  Output is the same shape as the C/C++ side's
# .link.dep.json, so dep_query.py treats Go targets uniformly.
#
# Adapted from production/demo/go/depgo.sh.
#
# Usage:
#   depgo.sh -p <module-root> [-s <subpkg>] -t <target-artifact> [-o <out.json>]

set -u

DEBUG=0
MODULE_ROOT=
SUBPKG=
TARGET_NAME=
OUTPUT_FILE=deps.json
GO=${GO:-go}

log_debug() {
    [ $DEBUG -eq 1 ] && echo "[DEBUG] $*" >&2 || true
}

log_error() {
    echo "[depgo] ERROR $*" >&2
}

usage() {
    cat >&2 <<EOF
Usage: $0 [options]
  -p|--path     Go module root (containing go.mod) [required]
  -s|--subpkg   Sub-package path relative to module root [optional]
  -t|--target   Target binary path [required]
  -o|--output   Output JSON path [default: deps.json]
  --debug       Verbose logging on stderr
EOF
    exit 1
}

TEMP=$(getopt -o p:s:t:o:h --long path:,subpkg:,target:,output:,debug,help -n "$0" -- "$@")
[ $? -ne 0 ] && usage
eval set -- "$TEMP"
while true; do
    case "$1" in
        -p|--path)    MODULE_ROOT=$(realpath "$2"); shift 2 ;;
        -s|--subpkg)  SUBPKG=$2; shift 2 ;;
        -t|--target)  TARGET_NAME=$2; shift 2 ;;
        -o|--output)  OUTPUT_FILE=$(realpath -m "$2"); shift 2 ;;
        --debug)      DEBUG=1; shift ;;
        -h|--help)    usage ;;
        --)           shift; break ;;
        *)            log_error "internal getopt error"; exit 1 ;;
    esac
done

[ -z "$MODULE_ROOT" ]            && { log_error "module path required (-p)"; usage; }
[ ! -f "$MODULE_ROOT/go.mod" ]   && { log_error "go.mod not found in $MODULE_ROOT"; exit 1; }
[ -z "$TARGET_NAME" ]            && TARGET_NAME=$(basename "$MODULE_ROOT")

log_debug "module: $MODULE_ROOT  subpkg: ${SUBPKG:-<all>}  target: $TARGET_NAME"


# Extract `module <name>` line from go.mod
get_module_name() {
    grep '^module ' "$MODULE_ROOT/go.mod" | awk '{print $2}'
}

# Collect every internal-package source file the entry pattern depends on
collect_deps() {
    local module_root=$1
    local pkg_pattern=$2

    cd "$module_root" || return 1
    local module_name
    module_name=$(get_module_name)
    log_debug "module name: $module_name"

    # internal-only deps: filter to those whose ImportPath starts with the
    # current module's prefix (stdlib + third-party live outside)
    local all_deps
    all_deps=$("$GO" list -deps -f '{{if not .Standard}}{{.ImportPath}}{{end}}' \
                  "$pkg_pattern" 2>/dev/null \
              | grep "^$module_name" | sort -u)

    log_debug "internal deps: $all_deps"

    # Collect EVERY relevant source category, not just .GoFiles.  A pkg
    # that uses cgo (`import "C"`) puts its .go sources in .CgoFiles;
    # its C/C++/header/assembly sidekicks live in .CFiles / .CXXFiles /
    # .HFiles / .SFiles.  Missing any of these means a change to that
    # file wouldn't invalidate the Go .dep.json.  See go help list.
    for pkg in $all_deps; do
        local pkg_info dir files
        pkg_info=$("$GO" list -f \
            '{{.Dir}}||{{.GoFiles}}||{{.CgoFiles}}||{{.CFiles}}||{{.CXXFiles}}||{{.HFiles}}||{{.SFiles}}' \
            "$pkg" 2>/dev/null) || continue
        [ -z "$pkg_info" ] && continue
        dir=${pkg_info%%||*}
        files=$(echo "${pkg_info#*||}" | tr '|' ' ' | tr -d '[],' | tr ' ' '\n' | grep -v '^$')
        while read -r file; do
            [ -n "$file" ] && echo "$dir/$file"
        done <<< "$files"
    done | sort -u

    # always include go.mod (any change to module deps invalidates everything)
    echo "$module_root/go.mod"

    # Return to the caller's cwd.  `|| return` guards against the
    # corner case where the OLDPWD directory got removed between our
    # earlier `cd $module_root` and now -- an unlikely but real race
    # (SC2164).  A failed cd- would silently leave the shell in the
    # module_root, tripping downstream commands with mysterious relative
    # path errors; returning propagates the failure loudly.
    cd - >/dev/null || return
}

# Also pull in any `replace` directives that point at local sibling modules
collect_replace_modules() {
    local module_root=$1
    local replace_paths
    replace_paths=$(grep '^replace' "$module_root/go.mod" 2>/dev/null | awk '{print $NF}' | grep '^\.\.')
    for rel_path in $replace_paths; do
        local abs_path
        abs_path=$(cd "$module_root" && realpath "$rel_path" 2>/dev/null)
        if [ -d "$abs_path" ] && [ -f "$abs_path/go.mod" ]; then
            log_debug "expanding replace module: $abs_path"
            collect_deps "$abs_path" "./..."
        fi
    done
}

emit_json() {
    local file=$1; shift
    local out=$1; shift
    mkdir -p "$(dirname "$out")"
    # Paths are emitted as-is (already absolute from earlier realpath
    # in the arg-parse phase).  Final `readlink -f` canonicalisation
    # happens at load time in pydep/dag.py -- keep this emit minimal.
    {
        printf '{\n  "file": "%s",\n  "deps": [' "$file"
        local first=1
        for d in "$@"; do
            [ -z "$d" ] && continue
            if [ "$first" = 1 ]; then
                printf '\n    "%s"' "$d"; first=0
            else
                printf ',\n    "%s"' "$d"
            fi
        done
        printf '\n  ]\n}\n'
    } > "$out.tmp" && mv "$out.tmp" "$out"
}

if [ -n "$SUBPKG" ]; then
    PKG_PATTERN="./$SUBPKG/..."
else
    PKG_PATTERN="./..."
fi

# Emit the file list, then de-dup & feed into the JSON writer
mapfile -t DEPS < <( { collect_deps "$MODULE_ROOT" "$PKG_PATTERN"; \
                        collect_replace_modules "$MODULE_ROOT"; } | sort -u )

emit_json "$TARGET_NAME" "$OUTPUT_FILE" "${DEPS[@]}"
