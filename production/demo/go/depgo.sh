#!/bin/bash

set -u

DEBUG=0
MODULE_ROOT=
SUBPKG=
TARGET_NAME=
OUTPUT_FILE=deps.json

log_debug() {
	[ $DEBUG -eq 1 ] && echo "[DEBUG] $*" >&2 || true
}

log_error() {
	echo "[ERROR] $*" >&2
}

usage() {
	echo "Usage: $0 [options]"
	echo "Options:"
	echo "  -p|--path:    Go module root path containing go.mod (required)"
	echo "  -s|--subpkg:  Sub-package path relative to module root (optional)"
	echo "                If not set, scans entire module (./...)"
	echo "  -t|--target:  Target binary path (required)"
	echo "  -o|--output:  Output JSON file path (optional, default: deps.json)"
	echo "  --debug:      Enable debug logging"
	echo "  -h|--help:    Show this help message"
	echo ""
	echo "Examples:"
	echo "  # Scan entire module"
	echo "  $0 -p /path/to/module -t myapp"
	echo ""
	echo "  # Scan specific sub-package and its dependencies"
	echo "  $0 -p /path/to/module -s cmd/server -t server"
	exit 1
}

TEMP=$(getopt -o p:s:t:o:h --long path:,subpkg:,target:,output:,debug,help -n "$0" -- "$@")
[ $? -ne 0 ] && usage
eval set -- "$TEMP"
while true; do
	case "$1" in
	-p | --path)
		MODULE_ROOT=$(realpath "$2")
		shift 2
		;;
	-s | --subpkg)
		SUBPKG=$2
		shift 2
		;;
	-t | --target)
		TARGET_NAME=$2
		shift 2
		;;
	-o | --output)
		OUTPUT_FILE=$(realpath "$2")
		shift 2
		;;
	--debug)
		DEBUG=1
		shift
		;;
	-h | --help)
		usage
		;;
	--)
		shift
		break
		;;
	*)
		log_error "Internal error!"
		exit 1
		;;
	esac
done

[ -z "$MODULE_ROOT" ] && {
	log_error "Module root path is required (-p/--path)"
	usage
}
[ ! -f "$MODULE_ROOT/go.mod" ] && {
	log_error "go.mod not found in $MODULE_ROOT"
	exit 1
}
[ -z "$TARGET_NAME" ] && TARGET_NAME=$(basename "$MODULE_ROOT")

log_debug "Module root: $MODULE_ROOT"
log_debug "Sub-package: ${SUBPKG:-<entire module>}"

# Get module name from go.mod
get_module_name() {
	grep "^module " "$MODULE_ROOT/go.mod" | awk '{print $2}'
}

# Collect source files for a package pattern, including internal dependencies
collect_deps() {
	local module_root=$1
	local pkg_pattern=$2

	cd "$module_root" || return 1

	local module_name=$(get_module_name)
	log_debug "Module name: $module_name"

	# Get all internal package dependencies using go list -deps
	local all_deps=$(go list -deps -f '{{if not .Standard}}{{.ImportPath}}{{end}}' "$pkg_pattern" 2>/dev/null | grep "^$module_name" | sort -u)

	log_debug "Internal dependencies: $all_deps"

	# Collect source files from each internal package
	for pkg in $all_deps; do
		log_debug "Processing package: $pkg"
		local pkg_info=$(go list -f '{{.Dir}} {{.GoFiles}}' "$pkg" 2>/dev/null)
		if [ -n "$pkg_info" ]; then
			local dir=$(echo "$pkg_info" | awk '{print $1}')
			local files=$(echo "$pkg_info" | cut -d' ' -f2- | tr -d '[],' | tr ' ' '\n' | grep -v '^$')
			while read -r file; do
				if [ -n "$file" ]; then
					local full_path="$dir/$file"
					log_debug "Adding file: $full_path"
					echo "$full_path"
				fi
			done <<<"$files"
		fi
	done | sort | uniq

	# Always add go.mod
	log_debug "Adding: $module_root/go.mod"
	echo "$module_root/go.mod"

	cd - >/dev/null
}

# Collect files from replace modules
collect_replace_modules() {
	local module_root=$1
	local replace_paths=$(grep "^replace" "$module_root/go.mod" 2>/dev/null | awk '{print $NF}' | grep "^\.\.")
	for rel_path in $replace_paths; do
		local abs_path=$(cd "$module_root" && realpath "$rel_path" 2>/dev/null)
		if [ -d "$abs_path" ] && [ -f "$abs_path/go.mod" ]; then
			log_debug "Checking replace module: $abs_path"
			collect_deps "$abs_path" "./..."
		fi
	done
}

generate_dep_json() {
	local target_name=$1
	local output_file=$2
	shift 2
	local deps_list="$*"

	echo "$deps_list" | tr ' ' '\n' | sort | uniq | jq -R -s 'split("\n") | map(select(length > 0)) | {"file": "'"$target_name"'", "deps": .}' >"$output_file"
}

# Determine package pattern
if [ -n "$SUBPKG" ]; then
	PKG_PATTERN="./$SUBPKG/..."
else
	PKG_PATTERN="./..."
fi

deps_list=$(collect_deps "$MODULE_ROOT" "$PKG_PATTERN") || exit 1
replace_files=$(collect_replace_modules "$MODULE_ROOT")
[ -n "$replace_files" ] && deps_list="$deps_list $replace_files"
generate_dep_json "$TARGET_NAME" "$OUTPUT_FILE" $deps_list
