#!/bin/bash

_dep_track_log() {
	[ -z "$DEP_TRACK_FILE" ] && return 0

	local op_type="$1"
	shift
	local dest="${@: -1}"
	local sources=("${@:1:$#-1}")

	# Normalize dest path - try realpath for any path type
	if [ -e "$dest" ] || [ -L "$dest" ]; then
		dest=$(realpath "$dest" 2>/dev/null || echo "$dest")
	fi

	# Build sources JSON array
	local json_sources="["
	local first=true
	for src in "${sources[@]}"; do
		# Try realpath for files, directories, and symlinks
		if [ -e "$src" ] || [ -L "$src" ]; then
			src=$(realpath "$src" 2>/dev/null || echo "$src")
		fi
		if [ "$first" = true ]; then
			json_sources+="\"$src\""
			first=false
		else
			json_sources+=",\"$src\""
		fi
	done
	json_sources+="]"

	# Check if this exact dependency already exists (deduplication)
	if [ -f "$DEP_TRACK_FILE" ]; then
		if grep -qF "\"sources\":$json_sources" "$DEP_TRACK_FILE" 2>/dev/null; then
			return 0 # Skip duplicate
		fi
	fi

	echo "{\"type\":\"$op_type\",\"sources\":$json_sources,\"dest\":\"$dest\"}" >>"$DEP_TRACK_FILE"
}

# Public API: Manually add dependencies
dep_add() {
	[ $# -eq 0 ] && echo "Usage: dep_add file1 [file2 ...]" >&2 && return 1
	[ -z "$DEP_TRACK_FILE" ] && return 0

	local json_sources="["
	local first=true
	for src in "$@"; do
		# Try realpath for files, directories, and symlinks
		if [ -e "$src" ] || [ -L "$src" ]; then
			src=$(realpath "$src" 2>/dev/null || echo "$src")
		fi
		if [ "$first" = true ]; then
			json_sources+="\"$src\""
			first=false
		else
			json_sources+=",\"$src\""
		fi
	done
	json_sources+="]"

	echo "{\"type\":\"manual\",\"sources\":$json_sources}" >>"$DEP_TRACK_FILE"
}

# Override cp command
cp() {
	local args=("$@") all_files=() skip_next=false
	for arg in "${args[@]}"; do
		[ "$skip_next" = true ] && skip_next=false && continue
		case "$arg" in
		-t | --target-directory | --suffix | --backup) skip_next=true ;;
		-*) ;;
		*) all_files+=("$arg") ;;
		esac
	done

	if [ ${#all_files[@]} -gt 1 ] && [ -n "$DEP_TRACK_FILE" ]; then
		local dest="${all_files[-1]}"
		unset 'all_files[-1]'
		_dep_track_log "cp" "${all_files[@]}" "$dest"
	fi

	command cp "$@"
}

# Override install command
install() {
	local args=("$@") all_files=()

	for arg in "${args[@]}"; do
		[[ ! "$arg" =~ ^- ]] && all_files+=("$arg")
	done

	if [ ${#all_files[@]} -ge 2 ] && [ -n "$DEP_TRACK_FILE" ]; then
		local dest="${all_files[-1]}"
		unset 'all_files[-1]'
		_dep_track_log "install" "${all_files[@]}" "$dest"
	fi

	command install "$@"
}

if [ "$DEP_TREE" = "yes" ]; then
	export DEP_TRACK_FILE="${DEP_TRACK_FILE:-dep_track_$$.jsonl}"
	mkdir -p "$(dirname "$DEP_TRACK_FILE")" 2>/dev/null || true
	[ ! -f "$DEP_TRACK_FILE" ] && echo "{\"session\":\"init\",\"pid\":$$,\"timestamp\":\"$(date -Iseconds)\"}" >"$DEP_TRACK_FILE"
	export -f cp install dep_add _dep_track_log
fi
