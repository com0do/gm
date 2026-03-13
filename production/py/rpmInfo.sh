#!/bin/bash
set -euo pipefail

: <<'COMMENT'
===============================================================================
Description: Batch query RPM version information from multiple repository sources
             Supports custom repos, extra repos, and Docker base image repo extraction
             Implements cache isolation per image for concurrent execution safety

Features:
  - Query RPM versions from yum/dnf repositories
  - Support multiple repo sources with priority ordering
  - Extract repos from Docker images or tar.gz URLs
  - Per-image cache isolation for parallel execution
  - Download resume support with progress bar
  - Automatic retry on network failures

===============================================================================
COMMENT

# Base cache directory (will be extended with image name for isolation)
# Cache expiration time, default 2 days (172800 seconds)
# Maximum retry count for failed repo queries
BASE_CACHE_DIR="${CACHE_DIR:-${HOME}/.cache/rpminfo_repodata}"
CACHE_EXPIRE_SECONDS="${CACHE_EXPIRE_SECONDS:-$((2*86400))}"
MAX_RETRY_COUNT="${MAX_RETRY_COUNT:-3}"

# ============================================================================
# Function: log_info, log_error, log_warn
# Description: Unified logging functions that output to stderr
# ============================================================================
log_info() {
	echo "$@" >&2
}

log_error() {
	echo "Error: $@" >&2
}

log_warn() {
	echo "Warning: $@" >&2
}

# ============================================================================
# Function: usage
# Description: Display usage information and exit
# ============================================================================
usage() {
	echo "Usage: $0 [--yum <repo_file>] [--image <image_name>] [--extra-repo <repo_file>] [--base_image <image>] [--arch <arch>] <rpm1> [rpm2] [rpm3] ..."
	echo ""
	echo "Options:"
	echo "  --yum <file>           - Custom yum repo file (optional, if not provided, will use base_image repos only)"
	echo "  --image <name>         - Image name for cache isolation (optional but recommended for parallel execution)"
	echo "  --extra-repo <file>    - Additional repo file to include (optional, for special images like hlrcallp/ss7stack)"
	echo "  --base_image <image>   - Docker base image or URL to extract repo configs from (optional)"
	echo "                           Supports: docker image name, http(s)://path/to/image.tar.gz"
	echo "  --arch <arch>          - Specify architecture: x86_64, i686, or noarch (optional)"
	echo "                           Default: automatically select best architecture (x86_64 > i686 > noarch)"
	echo ""
	echo "Examples:"
	echo "  $0 --yum yum.repo --image hlrcallp openssh sshpass glibc"
	echo "  $0 --yum yum.repo --image hss-hsscallp --base_image csfrockynano:25.11 openssh sshpass"
	echo "  $0 --yum yum.repo --image hlrcallp --extra-repo csf-rocky.repo --base_image ubi8:8.10 boost"
	echo "  $0 --image hss-lcmhook --base_image https://repo.cci.nokia.net/.../image.tar.gz openssh-clients sshpass"
	echo "  $0 --yum yum.repo --arch x86_64 unixODBC"
	echo "  $0 --yum yum.repo --arch i686 yajl"
	echo "  MAX_RETRY_COUNT=5 $0 --yum yum.repo openssl  # Retry 5 times on network failure"
	echo ""
	echo "Environment variables:"
	echo "  CACHE_DIR           - repodata cache directory (default: ~/.cache/rpminfo_repodata)"
	echo "  CACHE_EXPIRE_SECONDS - cache expiration seconds (default: 86400, i.e. 1 day)"
	echo "  MAX_RETRY_COUNT     - maximum retry count for failed repo queries (default: 3)"
	exit 1
}

# ============================================================================
# Function: parse_arguments
# Description: Parse command line arguments using getopt
# Returns: Sets global variables CUSTOM_REPO, BASE_IMAGE, RPM_NAMES_ORIGINAL
# ============================================================================
parse_arguments() {
	local TEMP
	TEMP=$(getopt -o 'h' --long help,yum:,image:,extra-repo:,base_image:,arch: -n "$0" -- "$@") || {
		log_error "Failed to parse arguments!"
		usage >&2
	}
	eval set -- "$TEMP"

	CUSTOM_REPO=""
	IMAGE_NAME=""
	declare -g -a EXTRA_REPOS=()
	BASE_IMAGE=""
	ARCH_FILTER=""

	while true; do
		case "$1" in
		-h | --help)
			usage >&2
			;;
		--yum)
			CUSTOM_REPO="$2"
			shift 2
			;;
		--image)
			IMAGE_NAME="$2"
			shift 2
			;;
		--extra-repo)
			EXTRA_REPOS+=("$2")
			shift 2
			;;
		--base_image)
			BASE_IMAGE="$2"
			shift 2
			;;
		--arch)
			ARCH_FILTER="$2"
			shift 2
			;;
		--)
			shift
			break
			;;
		*)
			log_error "Unknown option: $1"
			usage >&2
			;;
		esac
	done

	RPM_NAMES_ORIGINAL=("$@")
	if [ -z "$CUSTOM_REPO" ] && [ -z "$BASE_IMAGE" ]; then
		log_error "Either --yum or --base_image parameter is required!"
		usage >&2
	fi

	if [ ${#RPM_NAMES_ORIGINAL[@]} -eq 0 ]; then
		log_error "At least one RPM name is required!"
		usage >&2
	fi

	if [ -n "$CUSTOM_REPO" ] && [ ! -f "$CUSTOM_REPO" ]; then
		log_error "Custom repo file $CUSTOM_REPO does not exist!"
		exit 1
	fi

	for extra_repo in "${EXTRA_REPOS[@]}"; do
		if [ ! -f "$extra_repo" ]; then
			log_error "Extra repo file $extra_repo does not exist!"
			exit 1
		fi
	done
}

# ============================================================================
# Function: download_and_load_base_image
# Description: Download tar.gz image from URL and load it into Docker
# Arguments: $1 - Image URL (http:// or https://)
# Returns: Loaded docker image name, or exits on failure
# ============================================================================
download_and_load_base_image() {
	local image_url="$1"
	local tar_file
	tar_file=$(basename "$image_url")
	local download_dir="${BASE_CACHE_DIR}/downloads"

	mkdir -p "$download_dir"
	local tar_path="${download_dir}/${tar_file}"

	# Download if not already cached (with resume support and progress bar)
	if [ ! -f "$tar_path" ]; then
		log_info "Downloading base image to $tar_path..."
		# -c: resume download, --show-progress: show progress bar, -O: output file
		if ! wget -c --show-progress -O "$tar_path.tmp" "$image_url"; then
			log_error "Failed to download $image_url"
			rm -f "$tar_path.tmp"
			exit 1
		fi
		mv "$tar_path.tmp" "$tar_path"
		log_info "Download completed"
	else
		log_info "Using cached image: $tar_path"
	fi

	# Verify tar file integrity
	if ! tar -tzf "$tar_path" >/dev/null 2>&1; then
		log_error "Downloaded tar file is corrupted: $tar_path, removing and exiting..."
		rm -f "$tar_path"
		exit 1
	fi

	# Load into docker
	log_info "Loading image into Docker..."
	local load_output
	load_output=$(tar --to-stdout -xf "$tar_path" | docker load 2>&1)
	local repo_tag
	repo_tag=$(echo "$load_output" | grep "Loaded image: " | cut -d ' ' -f 3)

	if [ -z "$repo_tag" ]; then
		log_error "Couldn't get repo:tag from docker load output: $load_output"
		exit 1
	fi

	log_info "Successfully loaded image: $repo_tag"
	echo "$repo_tag"
}

# ============================================================================
# Function: extract_base_image_repos
# Description: Extract enabled repo configurations from a Docker base image
# Args: $1 - Docker image name
# Returns: Creates temporary repo files in CACHE_DIR/base_image_repos/
# ============================================================================
extract_base_image_repos() {
	local image="$1"
	local base_repo_dir="${CACHE_DIR}/base_image_repos"

	mkdir -p "$base_repo_dir"
	rm -f "$base_repo_dir"/*.repo 2>/dev/null || true

	log_info "Extracting repo configs from base image: $image"
	local temp_container="temp_rpminfo_$$"

	if ! docker create --name "$temp_container" "$image" /bin/true >/dev/null 2>&1; then
		log_warn "Failed to create container from image $image, skipping base image repos"
		return 1
	fi

	local cp_success=true
	docker cp "$temp_container":/etc/yum.repos.d/ "$base_repo_dir/" 2>/dev/null || cp_success=false
	docker rm "$temp_container" >/dev/null 2>&1

	if [ "$cp_success" = false ]; then
		log_warn "Failed to copy repo configs from image $image"
		return 1
	fi

	if ls "$base_repo_dir"/yum.repos.d/*.repo >/dev/null 2>&1; then
		cat "$base_repo_dir"/yum.repos.d/*.repo >"$base_repo_dir/combined.repo" 2>/dev/null
		rm -rf "$base_repo_dir"/yum.repos.d
	else
		log_warn "No .repo files found in /etc/yum.repos.d/"
		return 1
	fi

	if [ ! -s "$base_repo_dir/combined.repo" ]; then
		log_warn "No repo configs found in base image"
		return 1
	fi

	log_info "Successfully extracted repo configs from base image"
	return 0
}

# ============================================================================
# Function: validate_parameters
# Description: Validate and normalize RPM names
# Globals: RPM_NAMES, RPM_NAMES_CLEAN, RPM_NAME_MAP
# ============================================================================
validate_parameters() {
	if [[ -n "$ARCH_FILTER" ]] && [[ "$ARCH_FILTER" != "x86_64" ]] && [[ "$ARCH_FILTER" != "i686" ]] && [[ "$ARCH_FILTER" != "noarch" ]]; then
		log_error "Invalid architecture '$ARCH_FILTER'. Must be x86_64, i686, or noarch"
		exit 1
	fi

	# Clean RPM names: remove version/release suffix
	# e.g., "mapnik-utils-3.0.23" -> "mapnik-utils"
	# But keep: "java-17-openjdk" (17 is part of package name, not version)
	RPM_NAMES_CLEAN=()
	declare -g -A RPM_NAME_MAP
	for rpm in "${RPM_NAMES_ORIGINAL[@]}"; do
		clean_name="$rpm"
		# Only strip if pattern matches: -NUM.NUM or -NUM_text or -NUMtext-
		# This preserves "java-17-openjdk" but strips "mapnik-utils-3.0.23"
		if [[ "$rpm" =~ -[0-9]+\. ]] || [[ "$rpm" =~ -[0-9]+_ ]] || [[ "$rpm" =~ -[0-9]+[a-zA-Z]+-[0-9] ]]; then
			clean_name=$(echo "$rpm" | sed -E 's/-[0-9]+[0-9._a-zA-Z-]*$//')
		fi

		RPM_NAMES_CLEAN+=("$clean_name")
		RPM_NAME_MAP["$clean_name"]="$rpm"
	done

	RPM_NAMES=("${RPM_NAMES_CLEAN[@]}")
	if [ ${#RPM_NAMES[@]} -eq 0 ]; then
		log_error "No valid RPM names provided!"
		exit 1
	fi

	PM=$(command -v yum >/dev/null 2>&1 && echo "yum" || echo "dnf")
	if [ -z "$PM" ]; then
		log_error "Package manager not found (yum or dnf required)!"
		exit 1
	fi
}

# ============================================================================
# Function: parse_repo_file
# Description: Parse repo file and extract enabled repo names, baseurls, and priorities
# Args: $1 - repo file path
# Globals: REPO_URLS, REPO_PRIORITIES (associative arrays), REPO_NAMES (array)
# ============================================================================
parse_repo_file() {
	local repo_file="$1"
	local current_repo=""
	local current_baseurl=""
	local current_enabled=""
	local current_priority=""

	while IFS= read -r line; do
		line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
		[[ "$line" =~ ^#.*$ ]] && continue
		[ -z "$line" ] && continue
		if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then
			if [ -n "$current_repo" ] && [ -n "$current_baseurl" ]; then
				if [ "$current_enabled" = "1" ] || [ -z "$current_enabled" ]; then
					REPO_URLS["$current_repo"]="$current_baseurl"
					REPO_PRIORITIES["$current_repo"]="${current_priority:-99}"
					REPO_NAMES+=("$current_repo")
				fi
			fi
			current_repo="${BASH_REMATCH[1]}"
			current_baseurl=""
			current_enabled=""
			current_priority=""
		elif [[ "$line" =~ ^enabled[[:space:]]*=[[:space:]]*(.+)$ ]] && [ -n "$current_repo" ]; then
			current_enabled="${BASH_REMATCH[1]}"
		elif [[ "$line" =~ ^priority[[:space:]]*=[[:space:]]*(.+)$ ]] && [ -n "$current_repo" ]; then
			current_priority="${BASH_REMATCH[1]}"
		elif [[ "$line" =~ ^baseurl[[:space:]]*=[[:space:]]*(.+)$ ]] && [ -n "$current_repo" ]; then
			current_baseurl="${BASH_REMATCH[1]}"
		fi
	done <"$repo_file"

	if [ -n "$current_repo" ] && [ -n "$current_baseurl" ]; then
		if [ "$current_enabled" = "1" ] || [ -z "$current_enabled" ]; then
			REPO_URLS["$current_repo"]="$current_baseurl"
			REPO_PRIORITIES["$current_repo"]="${current_priority:-99}"
			REPO_NAMES+=("$current_repo")
		fi
	fi
}

# ============================================================================
# Function: merge_all_repos
# Description: Merge custom repo file and base image repos
# Globals: CUSTOM_REPO, BASE_IMAGE, REPO_URLS, REPO_PRIORITIES, REPO_NAMES
# ============================================================================
merge_all_repos() {
	declare -g -A REPO_URLS
	declare -g -A REPO_PRIORITIES
	declare -g -a REPO_NAMES=()

	# Handle base_image URL download if needed
	if [ -n "$BASE_IMAGE" ]; then
		if [[ "$BASE_IMAGE" == http://* ]] || [[ "$BASE_IMAGE" == https://* ]]; then
			log_info "Detected base_image URL, downloading and loading..."
			local loaded_image
			loaded_image=$(download_and_load_base_image "$BASE_IMAGE")
			BASE_IMAGE="$loaded_image"
			log_info "Base image updated to: $BASE_IMAGE"
		fi
	fi

	local custom_repo_count=0
	if [ -n "$CUSTOM_REPO" ]; then
		log_info "Parsing custom repo file: $CUSTOM_REPO"
		parse_repo_file "$CUSTOM_REPO"
		custom_repo_count=${#REPO_NAMES[@]}
		log_info "Found $custom_repo_count enabled repos in custom file"
	else
		log_info "No custom repo file provided, will use base_image repos only"
	fi

	local total_extra_repos=0
	for extra_repo in "${EXTRA_REPOS[@]}"; do
		local before_count=${#REPO_NAMES[@]}
		log_info "Parsing extra repo file: $extra_repo"
		parse_repo_file "$extra_repo"
		local after_count=${#REPO_NAMES[@]}
		local added_count=$((after_count - before_count))
		log_info "Found $added_count enabled repos in extra file"
		total_extra_repos=$((total_extra_repos + added_count))
	done
	local custom_and_extra_count=$((custom_repo_count + total_extra_repos))

	if [ -n "$BASE_IMAGE" ]; then
		if extract_base_image_repos "$BASE_IMAGE"; then
			local base_repo_file="${CACHE_DIR}/base_image_repos/combined.repo"
			if [ -f "$base_repo_file" ]; then
				log_info "Parsing base image repo configs"
				parse_repo_file "$base_repo_file"
				local total_count=${#REPO_NAMES[@]}
				local base_count=$((total_count - custom_and_extra_count))
				log_info "Found $base_count enabled repos in base image"
			fi
		fi
	fi

	local total_repos=${#REPO_NAMES[@]}
	if [ $total_repos -eq 0 ]; then
		log_error "No enabled repos found! Check your --yum, --extra-repo, or --base_image parameters."
		exit 1
	fi
	log_info "Total enabled repos: $total_repos"
	sort_repos_by_priority
}

# ============================================================================
# Function: sort_repos_by_priority
# Description: Sort REPO_NAMES array by priority (lower number = higher priority)
# Globals: REPO_NAMES, REPO_PRIORITIES
# ============================================================================
sort_repos_by_priority() {
	local temp_file=$(mktemp)
	for repo in "${REPO_NAMES[@]}"; do
		local priority="${REPO_PRIORITIES[$repo]:-99}"
		echo "$priority $repo" >>"$temp_file"
	done

	REPO_NAMES=()
	while IFS=' ' read -r priority repo; do
		REPO_NAMES+=("$repo")
	done < <(sort -n "$temp_file")
	rm -f "$temp_file"
}

# ============================================================================
# Function: query_repos_by_priority
# Description: Query repos in priority order (batch mode for efficiency)
#              Retries failed queries to ensure high-priority repos are not skipped
# Returns: Query results via stdout, respecting priority order
# ============================================================================
query_repos_by_priority() {
	declare -A found_packages
	local all_output=""

	for repo in "${REPO_NAMES[@]}"; do
		if [ -n "${REPO_URLS[$repo]:-}" ]; then
			local remaining_rpms=()
			for rpm_name in "${RPM_NAMES[@]}"; do
				if [ -z "${found_packages[$rpm_name]:-}" ]; then
					remaining_rpms+=("$rpm_name")
				fi
			done

			if [ ${#remaining_rpms[@]} -eq 0 ]; then
				break
			fi

			# Replace yum variables in repo URL
			local repo_url="${REPO_URLS[$repo]}"
			local arch_value="${ARCH_FILTER:-x86_64}"
			repo_url="${repo_url//\$basearch/$arch_value}"
			repo_url="${repo_url//\$releasever/8}"

			local query_cmd="$PM repoquery --info"
			query_cmd+=" --setopt=cachedir=$CACHE_DIR"
			query_cmd+=" --setopt=metadata_expire=${CACHE_EXPIRE_SECONDS}"
			query_cmd+=" --setopt=gpgcheck=0"
			query_cmd+=" --repofrompath=$repo,$repo_url"
			query_cmd+=" --repo=$repo"
			query_cmd+=" --arch=x86_64,i686,noarch"
			query_cmd+=" ${remaining_rpms[*]}"

			# Retry mechanism to ensure priority is respected
			local retry_count=0
			local result=""
			local query_success=false

			while [ $retry_count -lt $MAX_RETRY_COUNT ]; do
				result=$(eval "$query_cmd 2>&1")
				local exit_code=$?

				if [ $exit_code -eq 0 ]; then
					query_success=true
					break
				else
					((retry_count++))
					if [ $retry_count -lt $MAX_RETRY_COUNT ]; then
						log_warn "Query failed for repo [$repo] (priority ${REPO_PRIORITIES[$repo]:-99}), attempt $retry_count/$MAX_RETRY_COUNT: $(echo "$result" | grep -i error | head -1)"
						sleep 1
					fi
				fi
			done

			if [ "$query_success" = false ]; then
				log_error "Failed to query repo [$repo] after $MAX_RETRY_COUNT attempts, cannot proceed (skipping high-priority repo would violate priority order)"
				exit 1
			fi

			if [ -n "$result" ]; then
				all_output+="$result"$'\n'
				# Mark found packages to avoid querying them in lower priority repos
				local found_list=$(echo "$result" | awk '/^Name\s*:/ {print $NF}')
				for pkg in $found_list; do
					found_packages["$pkg"]=1
				done
			fi
		fi
	done

	echo "$all_output"
}

# ============================================================================
# Function: query_all_packages
# Description: Query all RPM packages respecting priority order (batch mode)
# Globals: RPM_NAMES
# Returns: Query results via stdout
# ============================================================================
query_all_packages() {
	query_repos_by_priority
}

# ============================================================================
# Function: parse_and_sort_results
# Description: Parse repoquery output and extract latest version for each package
# Args: $1 - input order (space-separated clean RPM names)
#       $2 - name mapping (clean_name=original_name pairs, space-separated)
#       $3 - architecture filter (optional: x86_64, i686, noarch, all, or empty for auto-priority)
# Stdin: repoquery output
# Stdout: Sorted results (original_name version release arch)
# ============================================================================
parse_and_sort_results() {
	local input_order="$1"
	local name_mapping="$2"
	local arch_filter="$3"

	awk -v input_order="$input_order" -v name_mapping="$name_mapping" -v arch_filter="$arch_filter" '
		BEGIN {
			FS = ": ";
			current_name = "";
			n = split(input_order, order_arr, / /);
			for (i = 1; i <= n; i++) {
				input_names[order_arr[i]] = i;
			}
			m = split(name_mapping, mapping_arr, / /);
			for (i = 1; i <= m; i++) {
				split(mapping_arr[i], kv, "=");
				if (length(kv) == 2) clean_to_orig[kv[1]] = kv[2];
			}
		}

		function get_arch_priority(arch) {
			return (arch == "x86_64") ? 1 : (arch == "i686") ? 2 : 3;
		}

		function save_package(name, ver, rel, arch) {
			if (name == "" || ver == "" || rel == "" || !(arch == "x86_64" || arch == "i686" || arch == "noarch")) return;
			if (arch_filter != "" && arch != arch_filter) return;

			if (name in pkg_versions) {
				if (arch_filter == "") {
					# Auto-priority mode: compare architecture first
					if (get_arch_priority(arch) < get_arch_priority(pkg_archs[name]) ||
					    (arch == pkg_archs[name] && compare_version(ver, rel, pkg_versions[name], pkg_releases[name]) > 0)) {
						pkg_versions[name] = ver;
						pkg_releases[name] = rel;
						pkg_archs[name] = arch;
					}
				} else {
					# Specific arch: just compare version
					if (compare_version(ver, rel, pkg_versions[name], pkg_releases[name]) > 0) {
						pkg_versions[name] = ver;
						pkg_releases[name] = rel;
					}
				}
			} else {
				pkg_versions[name] = ver;
				pkg_releases[name] = rel;
				pkg_archs[name] = arch;
				pkg_names[name] = name;
				pkg_order[name] = (name in input_names) ? input_names[name] : 9999;
			}
		}

		function compare_version(v1, r1, v2, r2,    n1, n2, a1, a2, max_n, i, p1, p2) {
			n1 = split(v1, a1, /[._-]/);
			n2 = split(v2, a2, /[._-]/);
			max_n = (n1 > n2) ? n1 : n2;
			for (i = 1; i <= max_n; i++) {
				p1 = (i <= n1) ? a1[i] : 0;
				p2 = (i <= n2) ? a2[i] : 0;
				if (p1 ~ /^[0-9]+$/ && p2 ~ /^[0-9]+$/) {
					if (p1 + 0 != p2 + 0) return (p1 + 0 > p2 + 0) ? 1 : 0;
				} else {
					if (p1 != p2) return (p1 > p2) ? 1 : 0;
				}
			}
			n1 = split(r1, a1, /[._-]/);
			n2 = split(r2, a2, /[._-]/);
			max_n = (n1 > n2) ? n1 : n2;
			for (i = 1; i <= max_n; i++) {
				p1 = (i <= n1) ? a1[i] : 0;
				p2 = (i <= n2) ? a2[i] : 0;
				gsub(/[^0-9].*/, "", p1); gsub(/[^0-9].*/, "", p2);
				if (p1 == "") p1 = 0;
				if (p2 == "") p2 = 0;
				if (p1 + 0 != p2 + 0) return (p1 + 0 > p2 + 0) ? 1 : 0;
			}
			return 0;
		}

		/^Name\s*:/ {
			save_package(current_name, version, release, pkg_arch);
			current_name = $2;
			gsub(/^[[:space:]]+/, "", current_name);
			version = release = pkg_arch = "";
		}

		/^Version\s*:/ { version = $2; gsub(/^[[:space:]]+/, "", version); }
		/^Release\s*:/ { release = $2; gsub(/^[[:space:]]+/, "", release); }
		/^Architecture\s*:/ { pkg_arch = $2; gsub(/^[[:space:]]+/, "", pkg_arch); }

		END {
			save_package(current_name, version, release, pkg_arch);
			for (name in pkg_names) {
				printf "%d\t%s %s %s %s\n", pkg_order[name], name, pkg_versions[name], pkg_releases[name], pkg_archs[name];
			}
			for (i = 1; i <= n; i++) {
				if (!(order_arr[i] in pkg_versions)) {
					printf "%d\t%s NOT_FOUND N/A N/A\n", i, order_arr[i];
				}
			}
		}
	' | sort -n | cut -f2-
}

# ============================================================================
# Function: main
# Description: Main execution flow
# ============================================================================
main() {
	parse_arguments "$@"
	validate_parameters

	if [ -n "$IMAGE_NAME" ]; then
		CACHE_DIR="${BASE_CACHE_DIR}/${IMAGE_NAME}"
	else
		CACHE_DIR="${BASE_CACHE_DIR}/$$"
		log_warn "No --image specified, using PID-based cache (not reusable)"
	fi

	mkdir -p "$CACHE_DIR"
	merge_all_repos

	local name_mapping=""
	for clean_name in "${RPM_NAMES_CLEAN[@]}"; do
		name_mapping+="${clean_name}=${RPM_NAME_MAP[$clean_name]} "
	done

	query_all_packages | parse_and_sort_results "${RPM_NAMES[*]}" "$name_mapping" "$ARCH_FILTER"
}

# ============================================================================
# Script Entry Point
# ============================================================================
main "$@"
