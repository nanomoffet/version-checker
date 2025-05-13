#!/usr/bin/env bash

# Script to check deployed service versions against GitHub releases
# Caching implemented ONLY for GitHub release info. Deployed versions are NOT cached.
# Processing is SEQUENTIAL.
#
# Dependencies: yq, jq, curl, gh, gum
# Requires Bash 4.3+ for associative array key check (-v)

# --- Configuration ---
CONFIG_FILE_CMD_OPT="" # Will be set by -f flag
DEFAULT_CONFIG_FILE="config.yaml"

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

# Filters (used for initial filtering based on config/interactive selection)
declare -a SELECTED_TENANTS
declare -a SELECTED_REGIONS # Still holds default/interactive selection for info, but *not* used for filtering when REGION_FILTER_MODE is 'off'
declare -a SELECTED_ENVIRONMENTS
declare -a SELECTED_SERVICES

# Command-line flags
VERBOSE=false
REGION_FILTER_MODE="off" # 'off', 'primary', 'secondary', 'all'
USER_SPECIFIED_REGION_VALUE="" # Stores the value provided to -r

# --- Helper Functions ---
log_error() { echo "ERROR: $1" >&2; }
log_info() { echo "INFO: $1"; }
log_debug() { [[ "$DEBUG" == "true" ]] && echo "DEBUG: $1" >&2; }
log_verbose() { [[ "$VERBOSE" == "true" ]] && echo "VERBOSE: $1" >&2; } # New verbose log

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
    # Check authentication status without producing output on success
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
  echo "Usage: $0 [-f <config_file>] [-c] [-v] [-r <region_mode>] [-h]"
  echo ""
  echo "Options:"
  echo "  -f <config_file>  Specify the YAML configuration file (default: config.yaml)."
  echo "  -c, --config      Interactively configure query filters and GitHub versions for comparison using gum."
  echo "  -v, --verbose     Show service URLs being called (concise list)."
  echo "  -r <region_mode>  Specify region selection mode. Overrides interactive/default region filter."
  echo "                    <region_mode> can be: 'off', 'primary', 'secondary', 'all'."
  echo "                    'off': DO NOT filter by region. Query only ONE instance per service/tenant/env combo. Region URL param is empty in the URL."
  echo "                    'primary': Select the first matching target instance for each service/tenant/env combination."
  echo "                    'secondary': Select the second matching target instance for each service/tenant/env combination."
  echo "                    'all': Include all matching targets regardless of region."
  echo "  -h, --help        Display this help message."
  echo ""
  echo "If -c is not used, the script uses defaults specified in the config file"
  echo "(or 'all' if defaults are not specific) and compares against the latest GitHub release."
  echo "The -r flag overrides the region filtering set by -c or config defaults if its value is not 'off'."
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
  if [[ -z "$sorted_first" || (""$sorted_first"" != ""$v1"" && ""$sorted_first"" != ""$v2"") ]]; then
    # Fallback for non-standard versions that sort -V might fail on
    if [[ "$v1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-.+)?$ && "$v2" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-.+)?$ ]]; then
        # If they look like standard versions but sort failed, something is wrong, mark as error
        return 3
    fi
     # Otherwise, maybe one is non-standard while the other is not? Treat as non-comparable.
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
  GITHUB_RELEASE_CACHE_TTL_SECONDS=$(yq e '.global.github_release_cache_ttl_seconds // "0"' "$CONFIG_FILE_TO_USE") # Default to 0 if null

  if [[ -z "$DEFAULT_CURL_TIMEOUT_SECONDS" || -z "$DEFAULT_VERSION_JQ_QUERY" || -z "$SERVICE_URL_TEMPLATE" ]]; then
    log_error "Global config error: Ensure default_curl_timeout_seconds, default_version_jq_query, service_url_template are set in $CONFIG_FILE_TO_USE."
    exit 1
  fi
  if ! [[ "$GITHUB_RELEASE_CACHE_TTL_SECONDS" =~ ^[0-9]+$ ]]; then
    log_error "Invalid github_release_cache_ttl_seconds in config. Must be a non-negative integer."
    exit 1
  fi
}

parse_defaults_from_config() {
  CONFIG_FILE_TO_USE="${CONFIG_FILE_CMD_OPT:-$DEFAULT_CONFIG_FILE}"
  # Use // "all" default directly with yq
  mapfile -t SELECTED_TENANTS < <(yq e '.defaults.tenants[] // "all"' "$CONFIG_FILE_TO_USE")
  mapfile -t SELECTED_ENVIRONMENTS < <(yq e '.defaults.environments[] // "all"' "$CONFIG_FILE_TO_USE")
  mapfile -t SELECTED_REGIONS < <(yq e '.defaults.regions[] // "all"' "$CONFIG_FILE_TO_USE") # Load default regions, but note they aren't used for filtering in 'off' mode
  mapfile -t SELECTED_SERVICES < <(yq e '.defaults.services[] // "all"' "$CONFIG_FILE_TO_USE")

  # Trim whitespace and handle potential 'null' or empty results from yq
  SELECTED_TENANTS=($(echo "${SELECTED_TENANTS[@]}" | xargs))
  SELECTED_ENVIRONMENTS=($(echo "${SELECTED_ENVIRONMENTS[@]}" | xargs))
  SELECTED_REGIONS=($(echo "${SELECTED_REGIONS[@]}" | xargs))
  SELECTED_SERVICES=($(echo "${SELECTED_SERVICES[@]}" | xargs))

  # Ensure 'all' is a single element if present and trim any null/empty entries
  SELECTED_TENANTS=($(echo "${SELECTED_TENANTS[@]}" | tr ' ' '\n' | grep -vE '^\s*$|null' | sort -u | xargs))
  SELECTED_ENVIRONMENTS=($(echo "${SELECTED_ENVIRONMENTS[@]}" | tr ' ' '\n' | grep -vE '^\s*$|null' | sort -u | xargs))
  # For regions in off mode, the specific values don't matter for filtering, but having "all" is a consistent default state.
  SELECTED_REGIONS=($(echo "${SELECTED_REGIONS[@]}" | tr ' ' '\n' | grep -vE '^\s*$|null' | sort -u | xargs))
  SELECTED_SERVICES=($(echo "${SELECTED_SERVICES[@]}" | tr ' ' '\n' | grep -vE '^\s*$|null' | sort -u | xargs))


   if [[ "${SELECTED_TENANTS[*]}" =~ (^| )all( |$) ]]; then SELECTED_TENANTS=("all"); fi
   if [[ "${SELECTED_ENVIRONMENTS[*]}" =~ (^| )all( |$) ]]; then SELECTED_ENVIRONMENTS=("all"); fi
   if [[ "${SELECTED_REGIONS[*]}" =~ (^| )all( |$) ]]; then SELECTED_REGIONS=("all"); fi # Default regions to "all" if config is empty/null/only whitespace
   if [[ "${SELECTED_SERVICES[*]}" =~ (^| )all( |$) ]]; then SELECTED_SERVICES=("all"); fi

   # Handle case where defaults were empty/null *after* trimming, ensure they become "all"
   if [[ ${#SELECTED_TENANTS[@]} -eq 0 ]]; then SELECTED_TENANTS=("all"); fi
   if [[ ${#SELECTED_ENVIRONMENTS[@]} -eq 0 ]]; then SELECTED_ENVIRONMENTS=("all"); fi
   if [[ ${#SELECTED_REGIONS[@]} -eq 0 ]]; then SELECTED_REGIONS=("all"); fi
   if [[ ${#SELECTED_SERVICES[@]} -eq 0 ]]; then SELECTED_SERVICES=("all"); fi


   log_debug "Loaded defaults: Tenants=${SELECTED_TENANTS[*]}, Envs=${SELECTED_ENVIRONMENTS[*]}, Regions=${SELECTED_REGIONS[*]}, Services=${SELECTED_SERVICES[*]}"

}

parse_services_repo_map() {
  CONFIG_FILE_TO_USE="${CONFIG_FILE_CMD_OPT:-$DEFAULT_CONFIG_FILE}"
  local service_keys_str
  service_keys_str=$(yq e '.services_repo_map | keys | .[]' "$CONFIG_FILE_TO_USE")
  mapfile -t service_keys < <(echo "$service_keys_str")

  if [[ ${#service_keys[@]} -eq 0 ]]; then
      log_error "No service keys found in services_repo_map in $CONFIG_FILE_TO_USE."
      exit 1
  fi

  for key in "${service_keys[@]}"; do
    # Check if key exists before trying to parse sub-keys
    if yq e ".services_repo_map | has(\"$key\")" "$CONFIG_FILE_TO_USE" | grep -q "true"; then
        SERVICES_REPO_MAP_DATA["$key,display_name"]=$(yq e ".services_repo_map[\"$key\"].display_name // \"$key\"" "$CONFIG_FILE_TO_USE") # Default display name
        SERVICES_REPO_MAP_DATA["$key,repo"]=$(yq e ".services_repo_map[\"$key\"].repo" "$CONFIG_FILE_TO_USE")
        SERVICES_REPO_MAP_DATA["$key,url_param_default"]=$(yq e ".services_repo_map[\"$key\"].url_param_default // \"$key\"" "$CONFIG_FILE_TO_USE") # Default url param

        if [[ -z "${SERVICES_REPO_MAP_DATA["$key,repo"]}" || "${SERVICES_REPO_MAP_DATA["$key,repo"]}" == "null" ]]; then
          log_error "Service key '$key' in services_repo_map is missing 'repo' information or it is null."
          exit 1
        fi
    else
        log_error "Service key '$key' found in keys but not as a map entry? Skipping."
    fi
  done
}


# --- Data Fetching ---
get_latest_github_release_tags() {
  local repo_name="$1"
  local limit="${2:-1}" # Default to 1 if no limit specified
  local release_tags_str
  local gh_stderr_file="$TMP_DIR/gh_stderr_releaselist_${repo_name//\//_}_$$.txt"

  # Use gh's built-in error handling where possible by checking exit status and stderr
  release_tags_str=$(gh release list --repo "$repo_name" --limit "$limit" --json tagName --jq '.[].tagName' 2>"$gh_stderr_file")
  local gh_status=$?
  local gh_stderr_output=""
  if [[ -f "$gh_stderr_file" ]]; then
    gh_stderr_output=$(cat "$gh_stderr_file")
    rm -f "$gh_stderr_file" # Clean up stderr file immediately
  fi

  if [[ $gh_status -ne 0 ]]; then
    if echo "$gh_stderr_output" | grep -q -i "Could not resolve to a Repository"; then
      log_error "GitHub repository not found: $repo_name"
      echo "ERR_GH_NOT_FOUND"
    elif echo "$gh_stderr_output" | grep -q -i "No releases found"; then
      log_debug "No releases found for repository: $repo_name"
      echo "NO_RELEASES"
    else
      log_error "gh CLI error for $repo_name (limit $limit): $gh_stderr_output"
      echo "ERR_GH_CLI($gh_status)"
    fi
    return 1 # Indicate failure
  fi
  if [[ -z "$release_tags_str" ]]; then
    log_debug "gh release list returned empty output for $repo_name."
    echo "NO_RELEASES"
    return 1 # Indicate failure
  fi
  echo "$release_tags_str" # Returns multiple tags separated by newlines
  return 0 # Indicate success
}


get_cached_or_fetch_latest_gh_release() {
  local repo_name="$1"
  local cache_file_tag="$CACHE_DIR/$GH_CACHE_SUBDIR/gh_release_tag_${repo_name//\//_}.txt"
  local cache_ts_file="$CACHE_DIR/$GH_CACHE_SUBDIR/gh_release_ts_${repo_name//\//_}.txt"
  local current_time
  current_time=$(date +%s)
  local release_tag="N/A_GH_FETCH"

  if [[ -v GITHUB_LATEST_VERSION_CACHE["$repo_name"] ]]; then # Check in-memory first
    log_debug "GH release cache HIT (in-memory) for $repo_name"
    echo "${GITHUB_LATEST_VERSION_CACHE["$repo_name"]}"
    return 0
  fi

  if [[ -f "$cache_file_tag" && -f "$cache_ts_file" ]]; then
    local cache_ts
    cache_ts=$(cat "$cache_ts_file")
    # Check TTL (only if TTL is positive)
    if [[ "$GITHUB_RELEASE_CACHE_TTL_SECONDS" -gt 0 ]] && ((current_time - cache_ts < GITHUB_RELEASE_CACHE_TTL_SECONDS)); then
      release_tag=$(cat "$cache_file_tag")
      # Only use cached tag if it's not an error marker
      if [[ -n "$release_tag" && "$release_tag" != ERR_* && "$release_tag" != "NO_RELEASES" ]]; then
        log_debug "GH release cache HIT (disk, valid TTL) for $repo_name"
        GITHUB_LATEST_VERSION_CACHE["$repo_name"]="$release_tag"
        echo "$release_tag"
        return 0
      fi
       log_debug "GH release cache MISS (disk, expired TTL or error marker) for $repo_name"
    else
      log_debug "GH release cache MISS (disk, no cache files or expired TTL) for $repo_name"
    fi
  else
      log_debug "GH release cache MISS (disk, no cache files) for $repo_name"
  fi

  log_debug "Fetching latest GH release for $repo_name..."
  mapfile -t latest_tags < <(get_latest_github_release_tags "$repo_name" 1)
  local fetch_status=$?

  release_tag="${latest_tags[0]}" # First tag from the list

  # Handle error results from get_latest_github_release_tags
  if [[ "$fetch_status" -ne 0 ]]; then
     # get_latest_github_release_tags already echoed the specific error/status
     : # release_tag already holds the error/status string like ERR_GH_* or NO_RELEASES
  elif [[ -z "$release_tag" ]]; then # Should be caught by NO_RELEASES from func, but double check
    release_tag="NO_RELEASES"
  else
    # Cache valid fetched tag to disk
    echo "$release_tag" >"$cache_file_tag"
    echo "$current_time" >"$cache_ts_file"
    log_debug "Cached GH release '$release_tag' for $repo_name"
  fi

  GITHUB_LATEST_VERSION_CACHE["$repo_name"]="$release_tag" # Cache in memory for this run
  echo "$release_tag"
}


get_deployed_version() {
  local service_url_param="$1" region_url_param_for_url="$2" effective_tenant="$3" effective_env="$4" jq_query="$5"
  local url="$SERVICE_URL_TEMPLATE"
  url="${url//\{service_url_param\}/$service_url_param}"
  # Use the passed region_url_param_for_url for URL construction
  url="${url//\{region_url_param\}/$region_url_param_for_url}"
  url="${url//\{effective_tenant\}/$effective_tenant}"
  url="${url//\{effective_env\}/$effective_env}"

  log_verbose "Fetching version from: $url" # Verbose output for URL

  local deployed_version="N/A_DEPLOY_FETCH" response
  response=$(curl --max-time "$DEFAULT_CURL_TIMEOUT_SECONDS" -s -L "$url")
  local http_status=$?

  if [[ $http_status -ne 0 ]]; then
    if [[ $http_status -eq 28 ]]; then deployed_version="TIMEOUT_SVC"; else deployed_version="ERR_SVC_CURL($http_status)"; fi
  else
    # Attempt to parse using jq query first
    deployed_version=$(echo "$response" | jq -r "$jq_query" 2>/dev/null)
    if [[ -z "$deployed_version" || "$deployed_version" == "null" ]]; then
      # If jq failed or returned null/empty, check if it's an HTTP error page or parse error
      local http_code_from_json
      http_code_from_json=$(echo "$response" | jq -r '.statusCode // .status // ""' 2>/dev/null)
      if [[ -n "$http_code_from_json" && "$http_code_from_json" != "null" ]]; then
         deployed_version="HTTP_$http_code_from_json"
      elif echo "$response" | grep -q -iE '<html>|<head>|Error'; then
         deployed_version="ERR_SVC_HTML_RESP"
      else
         deployed_version="ERR_SVC_PARSE"
      fi
    fi
  fi
  echo "$deployed_version"
}

# --- Gum Interactive Configuration ---
run_interactive_config() {
  CONFIG_FILE_TO_USE="${CONFIG_FILE_CMD_OPT:-$DEFAULT_CONFIG_FILE}"
  log_info "Starting interactive configuration using gum..."

  # Note: SELECTED_TENANTS, SELECTED_ENVIRONMENTS, SELECTED_REGIONS, SELECTED_SERVICES
  # are already populated with defaults before this function runs (see main).
  # Interactive selection will OVERRIDE these defaults if the user makes a selection.

  local all_tenants=($(yq e '.targets[].tenant' "$CONFIG_FILE_TO_USE" | sort -u | xargs))
  local all_environments=($(yq e '.targets[].environment' "$CONFIG_FILE_TO_USE" | sort -u | xargs))
  local all_regions=($(yq e '.targets[].region_url_param' "$CONFIG_FILE_TO_USE" | sort -u | xargs))
  local all_service_keys=($(yq e '.services_repo_map | keys | .[]' "$CONFIG_FILE_TO_USE" | sort -u | xargs))
  local all_service_display_names=()
  for skey in "${all_service_keys[@]}"; do
    local display_name="${SERVICES_REPO_MAP_DATA["$skey,display_name"]:-$skey}"
    all_service_display_names+=("$display_name ($skey)")
  done

  # Add "all" option to each filter list if they are not empty
  # If there are NO targets for a filter type, gum choose with empty list is okay.
  if [[ ${#all_tenants[@]} -gt 0 ]]; then all_tenants=("all" "${all_tenants[@]}"); fi
  if [[ ${#all_environments[@]} -gt 0 ]]; then all_environments=("all" "${all_environments[@]}"); fi
  # Region list for gum is only used if REGION_FILTER_MODE is 'off'
  if [[ ${#all_regions[@]} -gt 0 ]]; then all_regions=("all" "${all_regions[@]}"); fi


  if [[ ${#all_tenants[@]} -gt 0 ]]; then
    echo "Select tenants to query (current defaults: ${SELECTED_TENANTS[*]}):"
    mapfile -t SELECTED_TENANTS_GUM < <(gum choose --no-limit "${all_tenants[@]}")
    # Override default if selection was made (not empty)
    if [[ ${#SELECTED_TENANTS_GUM[@]} -gt 0 ]]; then SELECTED_TENANTS=("${SELECTED_TENANTS_GUM[@]}"); fi
  fi

  if [[ ${#all_environments[@]} -gt 0 ]]; then
    echo "Select environments to query (current defaults: ${SELECTED_ENVIRONMENTS[*]}):"
    mapfile -t SELECTED_ENVIRONMENTS_GUM < <(gum choose --no-limit "${all_environments[@]}")
     if [[ ${#SELECTED_ENVIRONMENTS_GUM[@]} -gt 0 ]]; then SELECTED_ENVIRONMENTS=("${SELECTED_ENVIRONMENTS_GUM[@]}"); fi
  fi

  # Handle Region Selection based on REGION_FILTER_MODE
  if [[ "$REGION_FILTER_MODE" == "off" ]]; then
      # When REGION_FILTER_MODE is 'off', region is NOT used for filtering targets based on their configured region_url_param.
      # However, interactive mode *allows* the user to set default filters
      # which might be used later if the mode was changed.
      # So, we still prompt, but explain its limited effect in 'off' mode.
      log_info "Region filter mode: '$REGION_FILTER_MODE'. Region selection below sets default for '--config' mode, but will NOT filter targets in 'off' mode (queries one instance per service/tenant/env combo)."
      if [[ ${#all_regions[@]} -gt 0 ]]; then
          mapfile -t SELECTED_REGIONS_GUM < <(gum choose --no-limit "${all_regions[@]}")
          # If interactive region selection is empty (user cancelled/selected none),
          # set SELECTED_REGIONS to "all" as a consistent default state for the filter variable.
          if [[ ${#SELECTED_REGIONS_GUM[@]} -eq 0 ]]; then
              log_debug "Interactive region selection was empty. Defaulting SELECTED_REGIONS filter variable to 'all'."
              SELECTED_REGIONS=("all")
          else
              SELECTED_REGIONS=("${SELECTED_REGIONS_GUM[@]}") # Use the gum selection for the filter variable
          fi
      else
          log_info "No regions found in config for interactive selection. Defaulting SELECTED_REGIONS filter variable to 'all'."
          SELECTED_REGIONS=("all") # No regions to select from, default to all for the filter variable
      fi
  else
      # For primary, secondary, all modes, interactive region selection is skipped.
      log_info "Region selection via gum skipped because -r '$USER_SPECIFIED_REGION_VALUE' was used (mode '$REGION_FILTER_MODE')."
      # SELECTED_REGIONS will retain the default value loaded before this function,
      # but its value is ignored by the main filter loop when mode is not 'off'.
  fi


  if [[ ${#all_service_display_names[@]} -gt 0 ]]; then
      echo "Select services to query (current defaults: ${SELECTED_SERVICES[*]}):"
      # Using display names for gum, then map back to service_keys
      mapfile -t selected_display_names < <(gum choose --no-limit "${all_service_display_names[@]}")
      if [[ ${#selected_display_names[@]} -gt 0 ]]; then
        SELECTED_SERVICES=() # Clear defaults potentially loaded before interactive mode
        for display_name_with_key in "${selected_display_names[@]}"; do
          # Extract service_key from "Display Name (service_key)"
          local skey_from_display=${display_name_with_key##*\(} # Get content after last (
          skey_from_display=${skey_from_display%\)*}            # Remove closing )
          SELECTED_SERVICES+=("$skey_from_display")
        done
      else
         # If user selected none, default back to 'all' services or keep previous defaults?
         # Let's keep the previous defaults if interactive resulted in empty selection
         log_info "No services selected interactively. Using default services: ${SELECTED_SERVICES[*]}."
      fi
  fi

  # For each *selected* service, prompt for GitHub version UNLESS 'all' services selected
  local effective_selected_services=("${SELECTED_SERVICES[@]}")
  if [[ "${effective_selected_services[0]}" == "all" ]]; then
     # If 'all' is selected, use all configured service keys from the map for the GH prompt step
     effective_selected_services=($(yq e '.services_repo_map | keys | .[]' "$CONFIG_FILE_TO_USE" | xargs))
  fi

  if [[ ${#effective_selected_services[@]} -gt 0 ]]; then
    for service_key_to_configure in "${effective_selected_services[@]}"; do
      # Ensure the service key is valid and has repo info before prompting for GH version
      if [[ -v SERVICES_REPO_MAP_DATA["$service_key_to_configure,repo"] ]]; then
        local repo_for_service="${SERVICES_REPO_MAP_DATA["$service_key_to_configure,repo"]}"
        local display_name_for_service="${SERVICES_REPO_MAP_DATA["$service_key_to_configure,display_name"]:-$service_key_to_configure}"

        echo "Fetching 5 latest releases for $display_name_for_service ($repo_for_service)..."
        mapfile -t latest_5_tags < <(get_latest_github_release_tags "$repo_for_service" 5)

        if [[ "${latest_5_tags[0]}" == ERR_* || "${latest_5_tags[0]}" == "NO_RELEASES" || ${#latest_5_tags[@]} -eq 0 ]]; then
          log_error "Could not fetch releases or no releases found for $display_name_for_service. Will use 'latest' logic for comparison."
          USER_SELECTED_GH_VERSIONS["$service_key_to_configure"]="latest" # Fallback marker
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
      else
          log_error "Service key '$service_key_to_configure' selected but not found in services_repo_map. Skipping GH version selection for this service."
          USER_SELECTED_GH_VERSIONS["$service_key_to_configure"]="latest" # Default to latest if repo unknown
      fi
    done
  else
    log_info "No services configured in config. Skipping GitHub version selection."
  fi
  log_info "Interactive configuration complete."
}

# --- Target Processing ---
process_target() {
  local target_json="$1"

  local target_name service_key environment tenant region_url_param service_url_param_override
  target_name=$(echo "$target_json" | jq -r '.name // "Unnamed Target"')
  service_key=$(echo "$target_json" | jq -r '.service_key')
  environment=$(echo "$target_json" | jq -r '.environment')
  tenant=$(echo "$target_json" | jq -r '.tenant')
  # Read the configured region_url_param from the target JSON (used for report, maybe for URL if not 'off')
  region_url_param=$(echo "$target_json" | jq -r '.region_url_param // "null"')
  service_url_param_override=$(echo "$target_json" | jq -r '.service_url_param_override // ""')

  # Ensure service_key exists in the map data
  if [[ ! -v SERVICES_REPO_MAP_DATA["$service_key,repo"] ]]; then
      log_error "Target '$target_name' refers to unknown service_key '$service_key'. Skipping."
      # Return a dummy result line for logging/error indication, but it won't be included in the final table
      echo "$target_name|N/A_UNKNOWN_SVC|N/A_UNKNOWN_SVC|${RED}UNKNOWN_SERVICE${NC}|Unknown Service ($service_key)|$tenant|$environment|$region_url_param|UNKNOWN_SERVICE"
      return 1 # Indicate failure
  fi

  local service_repo="${SERVICES_REPO_MAP_DATA["$service_key,repo"]}"
  local service_display_name="${SERVICES_REPO_MAP_DATA["$service_key,display_name"]:-$service_key}"
  local service_url_param_default="${SERVICES_REPO_MAP_DATA["$service_key,url_param_default"]:-$service_key}"
  local effective_service_url_param="$service_url_param_default"
  if [[ -n "$service_url_param_override" && "$service_url_param_override" != "null" ]]; then
    effective_service_url_param="$service_url_param_override"
  fi

  # Determine the GitHub reference version
  local github_reference_version
  # Check if a specific version was selected interactively and it's not the 'latest' marker
  if [[ -v USER_SELECTED_GH_VERSIONS["$service_key"] && "${USER_SELECTED_GH_VERSIONS["$service_key"]}" != "latest" ]]; then
    github_reference_version="${USER_SELECTED_GH_VERSIONS["$service_key"]}"
    log_debug "Using user-selected GH version ${github_reference_version} for $service_key"
  elif [[ -v USER_SELECTED_GH_VERSIONS["$service_key"] && "${USER_SELECTED_GH_VERSIONS["$service_key"]}" == "latest" ]]; then
     # Otherwise, fetch or use the cached latest release IF 'latest' was the selected mode
     github_reference_version=$(get_cached_or_fetch_latest_gh_release "$service_repo")
     log_debug "Using latest GH version ${github_reference_version} (cached or fetched) for $service_key"
  else
     # Fallback if service_key wasn't in USER_SELECTED_GH_VERSIONS (shouldn't happen if defaults are loaded correctly)
     log_debug "No GH version specified for $service_key, defaulting to latest."
     github_reference_version=$(get_cached_or_fetch_latest_gh_release "$service_repo")
  fi


  # --- Determine the actual region URL param to use for CURL ---
  # If the region mode is 'off', the URL template should use an empty string.
  # Otherwise, use the region_url_param from the target config.
  local region_url_param_for_curl="$region_url_param" # Default to the configured region from config
  if [[ "$REGION_FILTER_MODE" == "off" ]]; then
      log_debug "REGION_FILTER_MODE is 'off'. Setting region_url_param_for_curl to empty string for URL construction."
      region_url_param_for_curl="" # Override for URL building
  fi
  # --- End of region URL param logic ---

  local deployed_version
  # Pass the *effective* region parameter to the function that builds the URL
  deployed_version=$(get_deployed_version "$effective_service_url_param" "$region_url_param_for_curl" "$tenant" "$environment" "$DEFAULT_VERSION_JQ_QUERY")

  local status_text raw_status_text
  if [[ "$github_reference_version" == ERR_GH* || "$github_reference_version" == "N/A_GH_FETCH" ]]; then
    status_text="${RED}${github_reference_version}${NC}"
    raw_status_text="GH_ERROR"
  elif [[ "$github_reference_version" == "NO_RELEASES" ]]; then
    status_text="${CYAN}NO_GH_RELEASES${NC}" # Using Cyan for NO_RELE
