#!/usr/bin/env bash

# Script to check deployed service versions against GitHub releases
# Caching implemented ONLY for GitHub release info. Deployed versions are NOT cached.
# Processing is SEQUENTIAL.
#
# Dependencies: yq, jq, curl, gh, gum
# Requires Bash 4.3+ for associative array key check (-v)

# --- Configuration ---
CONFIG_FILE_CMD_OPT="" # Will be set by -f flag
DEFAULT_CONFIG_FILE="config.yml"

TMP_DIR="/tmp/version_checker_$$"
CACHE_DIR="$HOME/.cache/version_checker"
GH_CACHE_SUBDIR="github_releases"

mkdir -p "$TMP_DIR"
if ! mkdir -p "$CACHE_DIR/$GH_CACHE_SUBDIR"; then
  echo "ERROR: Could not create cache directory $CACHE_DIR/$GH_CACHE_SUBDIR" >&2
  exit 1
fi

# --- Global Variables & Associative Arrays ---
DEFAULT_CURL_TIMEOUT_SECONDS=""
DEFAULT_VERSION_JQ_QUERY=""
SERVICE_URL_TEMPLATE=""
GITHUB_RELEASE_CACHE_TTL_SECONDS=""

declare -A SERVICES_REPO_MAP_DATA
declare -A GITHUB_LATEST_VERSION_CACHE # In-memory cache for GH releases for *this run*
declare -A USER_SELECTED_GH_VERSIONS   # Stores service_key -> user_chosen_tag_for_comparison

# Filters
declare -a SELECTED_TENANTS
declare -a SELECTED_REGIONS
declare -a SELECTED_ENVIRONMENTS
declare -a SELECTED_SERVICES

# --- Helper Functions ---
log_error() { echo "ERROR: $1" >&2; }
log_info() { echo "INFO: $1"; }
log_debug() { [[ "$DEBUG" == "true" ]] && echo "DEBUG: $1" >&2; }

# Color definitions
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m' # For AHEAD status
CYAN=$'\033[0;36m'
NC=$'\033[0m'

# --- Dependency Checks ---
check_deps() {
  local missing_deps=0
  for cmd_tool in yq jq curl gh gum; do
    if ! command -v "$cmd_tool" &>/dev/null; then
      log_error "Required command '$cmd_tool' not found. Please install it."
      missing_deps=1
    fi
  done

  if command -v gh &>/dev/null; then
    local prev_opts=""
    if [[ $- == *e* ]]; then
      prev_opts="e"
      set +e
    fi
    gh auth status &>/dev/null
    local auth_status=$?
    if [[ -n "$prev_opts" ]]; then set -"$prev_opts"; fi
    if [[ $auth_status -ne 0 ]]; then
      log_error "GitHub CLI ('gh') is installed but not authenticated. Please run 'gh auth login'."
      missing_deps=1
    fi
  fi
  if [[ "$missing_deps" -eq 1 ]]; then exit 1; fi
}

# --- Usage/Help ---
print_usage() {
  echo "Usage: $0 [-f <config_file>] [-c] [-h]"
  echo ""
  echo "Options:"
  echo "  -f <config_file>  Specify the YAML configuration file (default: config.yaml)."
  echo "  -c, --config      Interactively configure query filters and GitHub versions for comparison using gum."
  echo "  -h, --help        Display this help message."
  echo ""
  echo "If -c is not used, the script uses defaults specified in the config file"
  echo "(or 'all' if defaults are not specific) and compares against the latest GitHub release."
}

# --- Version Comparison ---
compare_versions() {
  # Args: version1 (deployed), version2 (github_reference)
  # Returns EXIT STATUS:
  #   0 if version1 == version2 (UP-TO-DATE)
  #   1 if version1 > version2 (AHEAD)
  #   2 if version1 < version2 (OUTDATED)
  #   3 if error or non-standard/uncomparable versions (e.g., N/A, ERR_*)
  local v1="${1#v}" # Deployed
  local v2="${2#v}" # GitHub Reference

  # Handle N/A or error states directly using exit status 3
  if [[ "$v1" == N/A* || "$v1" == ERR_* || "$v1" == TIMEOUT_* || "$v1" == HTTP_* ]]; then return 3; fi
  if [[ "$v2" == N/A* || "$v2" == ERR_* || "$v2" == NO_RELEASES ]]; then return 3; fi

  # Check if they are identical first (common case)
  if [[ "$v1" == "$v2" ]]; then return 0; fi

  # Use sort -V for robust version comparison
  # Redirect stderr to /dev/null in case sort -V encounters invalid version strings
  local sorted_first
  sorted_first=$(printf '%s\n%s\n' "$v1" "$v2" | sort -V 2>/dev/null | head -n 1)

  # If sort -V had issues (e.g., non-version strings), $sorted_first might be unreliable.
  # As a basic check, if $sorted_first is empty or not one of the inputs, treat as non-comparable.
  if [[ -z "$sorted_first" || ("$sorted_first" != "$v1" && "$sorted_first" != "$v2") ]]; then
    return 3 # Treat as non-comparable
  fi

  if [[ "$sorted_first" == "$v1" ]]; then # v1 is smaller or equal
    # If they weren't identical initially, v1 must be smaller
    return 2 # v1 < v2 (OUTDATED)
  else       # $sorted_first must be $v2, meaning v1 is larger
    return 1 # v1 > v2 (AHEAD)
  fi
}

# --- YAML Parsing ---
parse_global_config() {
  CONFIG_FILE_TO_USE="${CONFIG_FILE_CMD_OPT:-$DEFAULT_CONFIG_FILE}"
  if [[ ! -f "$CONFIG_FILE_TO_USE" ]]; then
    log_error "Config file '$CONFIG_FILE_TO_USE' not found."
    exit 1
  fi
  log_info "Using configuration file: $CONFIG_FILE_TO_USE"

  DEFAULT_CURL_TIMEOUT_SECONDS=$(yq e '.global.default_curl_timeout_seconds' "$CONFIG_FILE_TO_USE")
  DEFAULT_VERSION_JQ_QUERY=$(yq e '.global.default_version_jq_query' "$CONFIG_FILE_TO_USE")
  SERVICE_URL_TEMPLATE=$(yq e '.global.service_url_template' "$CONFIG_FILE_TO_USE")
  GITHUB_RELEASE_CACHE_TTL_SECONDS=$(yq e '.global.github_release_cache_ttl_seconds // ""' "$CONFIG_FILE_TO_USE")

  if [[ -z "$DEFAULT_CURL_TIMEOUT_SECONDS" || -z "$DEFAULT_VERSION_JQ_QUERY" ||
    -z "$SERVICE_URL_TEMPLATE" || -z "$GITHUB_RELEASE_CACHE_TTL_SECONDS" ]]; then
    log_error "Global config error: Ensure default_curl_timeout_seconds, default_version_jq_query, service_url_template, github_release_cache_ttl_seconds are set."
    exit 1
  fi
  if ! [[ "$GITHUB_RELEASE_CACHE_TTL_SECONDS" =~ ^[0-9]+$ ]]; then
    log_error "Invalid github_release_cache_ttl_seconds. Must be an integer."
    exit 1
  fi
}

parse_defaults_from_config() {
  CONFIG_FILE_TO_USE="${CONFIG_FILE_CMD_OPT:-$DEFAULT_CONFIG_FILE}"
  SELECTED_TENANTS=($(yq e '.defaults.tenants[] // "all"' "$CONFIG_FILE_TO_USE" | tr '\n' ' '))
  SELECTED_ENVIRONMENTS=($(yq e '.defaults.environments[] // "all"' "$CONFIG_FILE_TO_USE" | tr '\n' ' '))
  SELECTED_REGIONS=($(yq e '.defaults.regions[] // "all"' "$CONFIG_FILE_TO_USE" | tr '\n' ' '))
  SELECTED_SERVICES=($(yq e '.defaults.services[] // "all"' "$CONFIG_FILE_TO_USE" | tr '\n' ' '))
}

parse_services_repo_map() {
  CONFIG_FILE_TO_USE="${CONFIG_FILE_CMD_OPT:-$DEFAULT_CONFIG_FILE}"
  local service_keys_str
  service_keys_str=$(yq e '.services_repo_map | keys | .[]' "$CONFIG_FILE_TO_USE")
  mapfile -t service_keys < <(echo "$service_keys_str")

  for key in "${service_keys[@]}"; do
    SERVICES_REPO_MAP_DATA["$key,display_name"]=$(yq e ".services_repo_map[\"$key\"].display_name" "$CONFIG_FILE_TO_USE")
    SERVICES_REPO_MAP_DATA["$key,repo"]=$(yq e ".services_repo_map[\"$key\"].repo" "$CONFIG_FILE_TO_USE")
    SERVICES_REPO_MAP_DATA["$key,url_param_default"]=$(yq e ".services_repo_map[\"$key\"].url_param_default" "$CONFIG_FILE_TO_USE")
    if [[ -z "${SERVICES_REPO_MAP_DATA["$key,repo"]}" ]]; then
      log_error "Service key '$key' in services_repo_map is missing 'repo' information."
      exit 1
    fi
  done
}

# --- Data Fetching ---
get_latest_github_release_tags() {
  local repo_name="$1"
  local limit="${2:-1}" # Default to 1 if no limit specified
  local release_tags_str
  local gh_stderr_file="$TMP_DIR/gh_stderr_releaselist_${repo_name//\//_}_$$.txt"

  release_tags_str=$(gh release list --repo "$repo_name" --limit "$limit" --json tagName --jq '.[].tagName' 2>"$gh_stderr_file")
  local gh_status=$?
  local gh_stderr_output=""
  if [[ -f "$gh_stderr_file" ]]; then
    gh_stderr_output=$(cat "$gh_stderr_file")
    rm -f "$gh_stderr_file"
  fi

  if [[ $gh_status -ne 0 ]]; then
    if echo "$gh_stderr_output" | grep -q -i "Could not resolve to a Repository"; then
      echo "ERR_GH_NOT_FOUND"
    elif echo "$gh_stderr_output" | grep -q -i "No releases found"; then
      echo "NO_RELEASES"
    else
      log_error "gh CLI error for $repo_name (limiting to $limit): $gh_stderr_output"
      echo "ERR_GH_CLI($gh_status)"
    fi
    return 1
  fi
  if [[ -z "$release_tags_str" ]]; then
    echo "NO_RELEASES"
    return 1
  fi
  echo "$release_tags_str" # Returns multiple tags separated by newlines
  return 0
}

get_cached_or_fetch_latest_gh_release() {
  local repo_name="$1"
  local cache_file_tag="$CACHE_DIR/$GH_CACHE_SUBDIR/gh_release_tag_${repo_name//\//_}.txt"
  local cache_ts_file="$CACHE_DIR/$GH_CACHE_SUBDIR/gh_release_ts_${repo_name//\//_}.txt"
  local current_time
  current_time=$(date +%s)
  local release_tag="N/A_GH_FETCH"

  if [[ -v GITHUB_LATEST_VERSION_CACHE["$repo_name"] ]]; then # Check in-memory first
    echo "${GITHUB_LATEST_VERSION_CACHE["$repo_name"]}"
    return 0
  fi

  if [[ -f "$cache_file_tag" && -f "$cache_ts_file" ]]; then
    local cache_ts
    cache_ts=$(cat "$cache_ts_file")
    if (((current_time - cache_ts) < GITHUB_RELEASE_CACHE_TTL_SECONDS)); then
      release_tag=$(cat "$cache_file_tag")
      if [[ -n "$release_tag" && "$release_tag" != ERR_* ]]; then
        GITHUB_LATEST_VERSION_CACHE["$repo_name"]="$release_tag"
        echo "$release_tag"
        return 0
      fi
    fi
  fi

  mapfile -t latest_tags < <(get_latest_github_release_tags "$repo_name" 1)
  release_tag="${latest_tags[0]}" # First tag from the list

  # Handle error results from get_latest_github_release_tags
  if [[ "$release_tag" == ERR_* || "$release_tag" == "NO_RELEASES" ]]; then
    :                                # Do nothing, release_tag already holds the error/status
  elif [[ -z "$release_tag" ]]; then # Should be caught by NO_RELEASES from func
    release_tag="NO_RELEASES"
  else
    # Cache valid fetched tag
    echo "$release_tag" >"$cache_file_tag"
    echo "$current_time" >"$cache_ts_file"
  fi

  GITHUB_LATEST_VERSION_CACHE["$repo_name"]="$release_tag"
  echo "$release_tag"
}

get_deployed_version() { # Unchanged, no caching for deployed versions
  local service_url_param="$1" region_url_param="$2" effective_tenant="$3" effective_env="$4" jq_query="$5"
  local url="$SERVICE_URL_TEMPLATE"
  url="${url//\{service_url_param\}/$service_url_param}"
  url="${url//\{region_url_param\}/$region_url_param}"
  url="${url//\{effective_tenant\}/$effective_tenant}"
  url="${url//\{effective_env\}/$effective_env}"

  local deployed_version="N/A_DEPLOY_FETCH" response
  response=$(curl --max-time "$DEFAULT_CURL_TIMEOUT_SECONDS" -s -L "$url")
  local http_status=$?

  if [[ $http_status -ne 0 ]]; then
    if [[ $http_status -eq 28 ]]; then deployed_version="TIMEOUT_SVC"; else deployed_version="ERR_SVC_CURL($http_status)"; fi
  else
    deployed_version=$(echo "$response" | jq -r "$jq_query" 2>/dev/null)
    if [[ -z "$deployed_version" || "$deployed_version" == "null" ]]; then
      local http_code_from_json
      http_code_from_json=$(echo "$response" | jq -r '.statusCode // .status // ""' 2>/dev/null)
      if [[ -n "$http_code_from_json" && "$http_code_from_json" != "null" ]]; then deployed_version="HTTP_$http_code_from_json"; else
        if echo "$response" | grep -q -iE '<html>|<head>|Error'; then deployed_version="ERR_SVC_HTML_RESP"; else deployed_version="ERR_SVC_PARSE"; fi
      fi
    fi
  fi
  echo "$deployed_version"
}

# --- Gum Interactive Configuration ---
run_interactive_config() {
  CONFIG_FILE_TO_USE="${CONFIG_FILE_CMD_OPT:-$DEFAULT_CONFIG_FILE}"
  log_info "Starting interactive configuration..."

  local all_tenants=($(yq e '.targets[].tenant' "$CONFIG_FILE_TO_USE" | sort -u | tr '\n' ' '))
  local all_environments=($(yq e '.targets[].environment' "$CONFIG_FILE_TO_USE" | sort -u | tr '\n' ' '))
  local all_regions=($(yq e '.targets[].region_url_param' "$CONFIG_FILE_TO_USE" | sort -u | tr '\n' ' '))
  local all_service_keys=($(yq e '.services_repo_map | keys | .[]' "$CONFIG_FILE_TO_USE" | sort -u | tr '\n' ' '))
  local all_service_display_names=()
  for skey in "${all_service_keys[@]}"; do
    all_service_display_names+=("$(yq e ".services_repo_map[\"$skey\"].display_name" "$CONFIG_FILE_TO_USE") ($skey)")
  done

  # Load defaults from config for pre-selection if possible, or just as info
  local default_tenants_cfg=($(yq e '.defaults.tenants[] // "all"' "$CONFIG_FILE_TO_USE" | tr '\n' ' '))
  # Similar for others... (gum doesn't directly support pre-selecting multiple items easily from an array)

  echo "Select tenants to query (current defaults: ${default_tenants_cfg[*]}):"
  mapfile -t SELECTED_TENANTS_GUM < <(gum choose --no-limit "${all_tenants[@]}")
  [[ ${#SELECTED_TENANTS_GUM[@]} -gt 0 ]] && SELECTED_TENANTS=("${SELECTED_TENANTS_GUM[@]}")

  echo "Select environments to query:"
  mapfile -t SELECTED_ENVIRONMENTS_GUM < <(gum choose --no-limit "${all_environments[@]}")
  [[ ${#SELECTED_ENVIRONMENTS_GUM[@]} -gt 0 ]] && SELECTED_ENVIRONMENTS=("${SELECTED_ENVIRONMENTS_GUM[@]}")

  echo "Select regions to query:"
  mapfile -t SELECTED_REGIONS_GUM < <(gum choose --no-limit "${all_regions[@]}")
  [[ ${#SELECTED_REGIONS_GUM[@]} -gt 0 ]] && SELECTED_REGIONS=("${SELECTED_REGIONS_GUM[@]}")

  echo "Select services to query:"
  # Using display names for gum, then map back to service_keys
  mapfile -t selected_display_names < <(gum choose --no-limit "${all_service_display_names[@]}")
  if [[ ${#selected_display_names[@]} -gt 0 ]]; then
    SELECTED_SERVICES=() # Clear defaults
    for display_name_with_key in "${selected_display_names[@]}"; do
      # Extract service_key from "Display Name (service_key)"
      local skey_from_display=${display_name_with_key##*\(} # Get content after last (
      skey_from_display=${skey_from_display%\)*}            # Remove closing )
      SELECTED_SERVICES+=("$skey_from_display")
    done
  fi

  # For each selected service, prompt for GitHub version
  if [[ "${SELECTED_SERVICES[0]}" != "all" && ${#SELECTED_SERVICES[@]} -gt 0 ]]; then
    for service_key_to_configure in "${SELECTED_SERVICES[@]}"; do
      local repo_for_service="${SERVICES_REPO_MAP_DATA["$service_key_to_configure,repo"]}"
      local display_name_for_service="${SERVICES_REPO_MAP_DATA["$service_key_to_configure,display_name"]}"

      echo "Fetching 5 latest releases for $display_name_for_service ($repo_for_service)..."
      mapfile -t latest_5_tags < <(get_latest_github_release_tags "$repo_for_service" 5)

      if [[ "${latest_5_tags[0]}" == ERR_* || "${latest_5_tags[0]}" == "NO_RELEASES" ]]; then
        log_error "Could not fetch releases for $display_name_for_service. Will use 'latest' logic for comparison."
        USER_SELECTED_GH_VERSIONS["$service_key_to_configure"]="latest" # Fallback
        continue
      fi
      if [[ ${#latest_5_tags[@]} -eq 0 ]]; then
        log_error "No releases found for $display_name_for_service. Will use 'latest' logic."
        USER_SELECTED_GH_VERSIONS["$service_key_to_configure"]="latest" # Fallback
        continue
      fi

      local gum_options=("Use latest GitHub release (auto)" "${latest_5_tags[@]}")
      echo "Choose GitHub version for comparison for $display_name_for_service:"
      chosen_version=$(gum choose "${gum_options[@]}")

      if [[ "$chosen_version" == "Use latest GitHub release (auto)" || -z "$chosen_version" ]]; then
        USER_SELECTED_GH_VERSIONS["$service_key_to_configure"]="latest" # Special marker
      else
        USER_SELECTED_GH_VERSIONS["$service_key_to_configure"]="$chosen_version"
      fi
    done
  else
    log_info "All services selected, or no specific services. Version comparison will use latest GitHub release for all."
  fi
  log_info "Interactive configuration complete."
}

# --- Target Processing ---
process_target() {
  local target_json="$1"

  local target_name service_key environment tenant region_url_param service_url_param_override
  target_name=$(echo "$target_json" | jq -r '.name')
  service_key=$(echo "$target_json" | jq -r '.service_key')
  environment=$(echo "$target_json" | jq -r '.environment')
  tenant=$(echo "$target_json" | jq -r '.tenant')
  region_url_param=$(echo "$target_json" | jq -r '.region_url_param')
  service_url_param_override=$(echo "$target_json" | jq -r '.service_url_param_override // ""')

  local service_repo="${SERVICES_REPO_MAP_DATA["$service_key,repo"]}"
  local service_display_name="${SERVICES_REPO_MAP_DATA["$service_key,display_name"]}"
  local service_url_param_default="${SERVICES_REPO_MAP_DATA["$service_key,url_param_default"]}"
  local effective_service_url_param="$service_url_param_default"
  if [[ -n "$service_url_param_override" && "$service_url_param_override" != "null" ]]; then
    effective_service_url_param="$service_url_param_override"
  fi

  # Determine the GitHub reference version
  local github_reference_version
  if [[ -v USER_SELECTED_GH_VERSIONS["$service_key"] && "${USER_SELECTED_GH_VERSIONS["$service_key"]}" != "latest" ]]; then
    github_reference_version="${USER_SELECTED_GH_VERSIONS["$service_key"]}"
  else
    github_reference_version=$(get_cached_or_fetch_latest_gh_release "$service_repo")
  fi

  local deployed_version
  deployed_version=$(get_deployed_version "$effective_service_url_param" "$region_url_param" "$tenant" "$environment" "$DEFAULT_VERSION_JQ_QUERY")

  local status_text raw_status_text
  if [[ "$github_reference_version" == ERR_GH* || "$github_reference_version" == "N/A_GH_FETCH" ]]; then
    status_text="${RED}${github_reference_version}${NC}"
    raw_status_text="GH_ERROR"
  elif [[ "$github_reference_version" == "NO_RELEASES" ]]; then
    status_text="${CYAN}NO_GH_RELEASES${NC}" # Using Cyan for NO_RELEASES for differentiation
    raw_status_text="NO_GH_RELEASES"
  elif [[ "$deployed_version" == TIMEOUT_SVC* || "$deployed_version" == ERR_SVC* || "$deployed_version" == HTTP_* || "$deployed_version" == N/A* ]]; then
    status_text="${RED}${deployed_version}${NC}"
    raw_status_text="SVC_ERROR"
  else
    compare_versions "$deployed_version" "$github_reference_version"
    local comparison_result=$?
    case $comparison_result in
    0)
      status_text="${GREEN}UP-TO-DATE${NC}"
      raw_status_text="UP-TO-DATE"
      ;;
    1)
      status_text="${BLUE}AHEAD${NC}"
      raw_status_text="AHEAD"
      ;; # Deployed is newer
    2)
      status_text="${YELLOW}OUTDATED${NC}"
      raw_status_text="OUTDATED"
      ;; # Deployed is older
    *)
      status_text="${YELLOW}NEEDS_CMP_FIX ($deployed_version vs $github_reference_version)${NC}"
      raw_status_text="UNKNOWN_CMP"
      ;; # Fallback
    esac
  fi
  echo "$target_name|$deployed_version|$github_reference_version|$status_text|$service_display_name|$tenant|$environment|$region_url_param|$raw_status_text"
}


# ---- [ABOVE main()] ----

SHOW_VERBOSE_URLS=false
REGION_FLAG="off"

# Parse our new CLI flags in addition to the others
main() {
  INTERACTIVE_CONFIG_MODE=false
  SHOW_VERBOSE_URLS=false
  REGION_FLAG="off"

  # --- Enhanced CLI argument parsing ---
  while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
      -f)
        CONFIG_FILE_CMD_OPT="$2"
        shift 2
        ;;
      -c)
        INTERACTIVE_CONFIG_MODE=true
        shift
        ;;
      -h|--help)
        print_usage
        exit 0
        ;;
      -v|--verbose)
        SHOW_VERBOSE_URLS=true
        shift
        ;;
      --region)
        if [[ "$2" == "primary" || "$2" == "secondary" || "$2" == "all" || "$2" == "off" ]]; then
          REGION_FLAG="$2"
        else
          log_error "Invalid value for --region. Allowed: off, primary, secondary, all"
          exit 1
        fi
        shift 2
        ;;
      *)
        break
        ;;
    esac
  done

  check_deps
  parse_global_config
  parse_services_repo_map

  if $INTERACTIVE_CONFIG_MODE; then
    run_interactive_config
  else
    parse_defaults_from_config
    log_info "Using default filters: Tenants=${SELECTED_TENANTS[*]}, Envs=${SELECTED_ENVIRONMENTS[*]}, Regions=${SELECTED_REGIONS[*]}, Services=${SELECTED_SERVICES[*]}"
    log_info "Version comparison will use latest GitHub release for all services."
  fi

  CONFIG_FILE_TO_USE="${CONFIG_FILE_CMD_OPT:-$DEFAULT_CONFIG_FILE}"
  local all_targets_json
  all_targets_json=$(yq e -o=json '.targets' "$CONFIG_FILE_TO_USE")
  if [[ -z "$all_targets_json" || "$all_targets_json" == "null" ]]; then
    log_error "No targets found in $CONFIG_FILE_TO_USE or error parsing targets."
    exit 1
  fi

  declare -a filtered_targets_json_array=()
  local num_all_targets
  num_all_targets=$(echo "$all_targets_json" | jq 'length')

  for i in $(seq 0 $((num_all_targets - 1))); do
    local current_target_json
    current_target_json=$(echo "$all_targets_json" | jq -c ".[$i]")
    local t_tenant t_env t_region t_service_key
    t_tenant=$(echo "$current_target_json" | jq -r '.tenant')
    t_env=$(echo "$current_target_json" | jq -r '.environment')
    t_region=$(echo "$current_target_json" | jq -r '.region_url_param')
    t_service_key=$(echo "$current_target_json" | jq -r '.service_key')

    # Apply filters
    local tenant_match=false env_match=false region_match=false service_match=false
    if [[ "${SELECTED_TENANTS[0]}" == "all" || " ${SELECTED_TENANTS[*]} " =~ " $t_tenant " ]]; then tenant_match=true; fi
    if [[ "${SELECTED_ENVIRONMENTS[0]}" == "all" || " ${SELECTED_ENVIRONMENTS[*]} " =~ " $t_env " ]]; then env_match=true; fi
    if [[ "${SELECTED_REGIONS[0]}" == "all" || " ${SELECTED_REGIONS[*]} " =~ " $t_region " ]]; then region_match=true; fi
    if [[ "${SELECTED_SERVICES[0]}" == "all" || " ${SELECTED_SERVICES[*]} " =~ " $t_service_key " ]]; then service_match=true; fi

    if $tenant_match && $env_match && $region_match && $service_match; then
      filtered_targets_json_array+=("$current_target_json")
    fi
  done

  # --- Apply region filtering ---
  declare -a targets_after_region=()
  declare -A seen_primary_combo
  declare -A secondary_count_combo
  for target in "${filtered_targets_json_array[@]}"; do
    region_val=$(echo "$target" | jq -r '.region_url_param // ""')
    skey=$(echo "$target" | jq -r '.service_key')
    env=$(echo "$target" | jq -r '.environment')
    tenant=$(echo "$target" | jq -r '.tenant')
    combo_id="${skey}|${env}|${tenant}"

    case "$REGION_FLAG" in
      "off")
        targets_after_region+=("$target")
        ;;
      "primary")
        if [[ -z "${seen_primary_combo[$combo_id]}" ]]; then
          targets_after_region+=("$target")
          seen_primary_combo["$combo_id"]=1
        fi
        ;;
      "secondary")
        if [[ -z "${secondary_count_combo[$combo_id]}" ]]; then
          secondary_count_combo["$combo_id"]=1
        elif [[ "${secondary_count_combo[$combo_id]}" -eq 1 ]]; then
          targets_after_region+=("$target")
          secondary_count_combo["$combo_id"]=2
        fi
        ;;
      "all")
        targets_after_region+=("$target")
        ;;
    esac
  done

  local num_filtered_targets=${#targets_after_region[@]}
  if [[ "$num_filtered_targets" -eq 0 ]]; then
    log_info "No targets match the current filter criteria (after region filtering). Exiting."
    exit 0
  fi
  log_info "Processing $num_filtered_targets targets sequentially (after region filtering)."

  # --- Verbose output of URLs ---
  if $SHOW_VERBOSE_URLS; then
    echo "Service URLs to be called (one per target):"
    for target_json in "${targets_after_region[@]}"; do
      service_key=$(echo "$target_json" | jq -r '.service_key')
      environment=$(echo "$target_json" | jq -r '.environment')
      tenant=$(echo "$target_json" | jq -r '.tenant')
      region_url_param=$(echo "$target_json" | jq -r '.region_url_param')
      service_url_param_override=$(echo "$target_json" | jq -r '.service_url_param_override // ""')
      service_url_param="${SERVICES_REPO_MAP_DATA["$service_key,url_param_default"]}"
      [[ -n "$service_url_param_override" && "$service_url_param_override" != "null" ]] && service_url_param="$service_url_param_override"
      url="$SERVICE_URL_TEMPLATE"
      url="${url//\{service_url_param\}/$service_url_param}"
      url="${url//\{region_url_param\}/$region_url_param}"
      url="${url//\{effective_tenant\}/$tenant}"
      url="${url//\{effective_env\}/$environment}"
      display_name="${SERVICES_REPO_MAP_DATA["$service_key,display_name"]}"
      printf "[%s | %s | %s | %s] %s\n" "$display_name" "$tenant" "$environment" "$region_url_param" "$url"
    done
    echo "---- End of service URL list ----"
  fi

  declare -a results_array=()
  for i in $(seq 0 $((num_filtered_targets - 1))); do
    local target_item_json="${targets_after_region[$i]}"
    local target_name_for_progress
    target_name_for_progress=$(echo "$target_item_json" | jq -r '.name // "Unknown Target"')
    printf "\rProcessing target %s/%s: %s..." "$((i + 1))" "$num_filtered_targets" "$target_name_for_progress"

    local result_line
    result_line=$(process_target "$target_item_json")
    if [[ -n "$result_line" ]]; then results_array+=("$result_line"); else
      log_error "Processing failed for '$target_name_for_progress' (index $i), no result returned."
    fi
  done

  printf "\n"
  log_info "All targets processed. Generating report..."

  # Output Table Generation (same as before)
  local max_name_len=12 max_deployed_len=10 max_latest_len=10 max_service_len=15 max_tenant_len=7 max_env_len=5 max_region_len=8

  max_name_len=$(($(echo "Target Instance" | wc -m) > max_name_len ? $(echo "Target Instance" | wc -m) : max_name_len))
  max_deployed_len=$(($(echo "Deployed" | wc -m) > max_deployed_len ? $(echo "Deployed" | wc -m) : max_deployed_len))
  max_latest_len=$(($(echo "GH Ref Ver" | wc -m) > max_latest_len ? $(echo "GH Ref Ver" | wc -m) : max_latest_len))
  max_service_len=$(($(echo "Service" | wc -m) > max_service_len ? $(echo "Service" | wc -m) : max_service_len))
  max_tenant_len=$(($(echo "Tenant" | wc -m) > max_tenant_len ? $(echo "Tenant" | wc -m) : max_tenant_len))
  max_env_len=$(($(echo "Env" | wc -m) > max_env_len ? $(echo "Env" | wc -m) : max_env_len))
  max_region_len=$(($(echo "Region" | wc -m) > max_region_len ? $(echo "Region" | wc -m) : max_region_len))

  for line in "${results_array[@]}"; do
    local name deployed latest _ service tenant env region _
    IFS='|' read -r name deployed latest _ service tenant env region _ <<<"$line"
    ((${#name} > max_name_len)) && max_name_len=${#name}
    ((${#deployed} > max_deployed_len)) && max_deployed_len=${#deployed}
    ((${#latest} > max_latest_len)) && max_latest_len=${#latest}
    ((${#service} > max_service_len)) && max_service_len=${#service}
    ((${#tenant} > max_tenant_len)) && max_tenant_len=${#tenant}
    ((${#env} > max_env_len)) && max_env_len=${#env}
    ((${#region} > max_region_len)) && max_region_len=${#region}
  done

  max_name_len=$((max_name_len + 1))
  max_deployed_len=$((max_deployed_len + 1))
  max_latest_len=$((max_latest_len + 1))
  max_service_len=$((max_service_len + 1))
  max_tenant_len=$((max_tenant_len + 1))
  max_env_len=$((max_env_len + 1))
  max_region_len=$((max_region_len + 1))

  local format_string="%-*s | %-*s | %-*s | %-*s | %-*s | %-*s | %-*s | %s\n"
  printf "\n--- Service Version Status (Generated: $(date)) ---\n"
  printf "$format_string" \
    "$max_service_len" "Service" "$max_tenant_len" "Tenant" "$max_env_len" "Env" "$max_region_len" "Region" \
    "$max_name_len" "Target Instance" "$max_deployed_len" "Deployed" "$max_latest_len" "GH Ref Ver" "Status"

  local total_width=$((max_service_len + max_tenant_len + max_env_len + max_region_len + max_name_len + max_deployed_len + max_latest_len + 7 * 3 + 15))
  printf "%${total_width}s\n" "" | tr " " "-"

  declare -a sorted_results=()
  while IFS= read -r line; do sorted_results+=("$line"); done < <(
    printf "%s\n" "${results_array[@]}" |
      awk -F'|' '
      function status_sort_key(status) {
          if (status == "GH_ERROR") return 1; if (status == "SVC_ERROR") return 2;
          if (status == "AHEAD") return 3; if (status == "OUTDATED") return 4;
          if (status == "NO_GH_RELEASES") return 5; if (status == "UP-TO-DATE") return 6;
          return 7;
      }
      { print status_sort_key($9) "|" $0 }' |
      sort -t'|' -k1,1n -k6,6 -k7,7 -k8,8 | cut -d'|' -f2-
  )

  for line in "${sorted_results[@]}"; do
    local target_name_val deployed_val gh_ref_ver_val status_val service_val tenant_val env_val region_val _
    IFS='|' read -r target_name_val deployed_val gh_ref_ver_val status_val service_val tenant_val env_val region_val _ <<<"$line"
    printf "$format_string" \
      "$max_service_len" "$service_val" "$max_tenant_len" "$tenant_val" "$max_env_len" "$env_val" "$max_region_len" "$region_val" \
      "$max_name_len" "$target_name_val" "$max_deployed_len" "$deployed_val" "$max_latest_len" "$gh_ref_ver_val" "$status_val"
  done

  log_info "Cleaning up temporary directory: $TMP_DIR"
  if [[ -d "$TMP_DIR" && "$TMP_DIR" == /tmp/version_checker_* ]]; then rm -rf "$TMP_DIR"; else
    if [[ -n "$TMP_DIR" ]]; then log_error "Skipping cleanup of unexpected TMP_DIR: $TMP_DIR"; fi
  fi
}

# --- Trap for cleanup ---
cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" && "$TMP_DIR" == /tmp/version_checker_* ]]; then
    log_info "Script interrupted/finished. Cleaning up $TMP_DIR..."
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT SIGINT SIGTERM

# --- Run ---
main "$@"
