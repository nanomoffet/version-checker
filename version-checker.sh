#!/usr/bin/env bash

# Script to check deployed service versions against GitHub releases
# Caching implemented ONLY for GitHub release info. Deployed versions are NOT cached.
# Processing is SEQUENTIAL.
#
# Dependencies: yq, jq, curl, gh, gum
# Requires Bash 4.3+ for associative array key check (-v)
# --- Configuration ---
CONFIG_FILE_CMD_OPT=""
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
declare -A GITHUB_LATEST_VERSION_CACHE
declare -A USER_SELECTED_GH_VERSIONS

declare -a SELECTED_TENANTS
declare -a SELECTED_REGIONS
declare -a SELECTED_ENVIRONMENTS
declare -a SELECTED_SERVICES

VERBOSE=false
REGION_FILTER_MODE="off"
USER_SPECIFIED_REGION_VALUE=""

log_error() { echo "ERROR: $1" >&2; }
log_info() { echo "INFO: $1"; }
log_debug() { [[ "$DEBUG" == "true" ]] && echo "DEBUG: $1" >&2; }
log_verbose() { [[ "$VERBOSE" == "true" ]] && echo "VERBOSE: $1" >&2; }

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

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

print_usage() {
  echo "Usage: $0 [-f <config_file>] [-c] [-v] [-r <region_mode>] [-h]"
  echo ""
  echo "Options:"
  echo "  -f <config_file>  Specify the YAML configuration file (default: config.yaml)."
  echo "  -c, --config      Interactively configure query filters and GitHub versions for comparison using gum."
  echo "  -v, --verbose     Show service URLs being called (concise list)."
  echo "  -r <region_mode>  Specify region selection mode. Overrides interactive/default region filter."
  echo "  -h, --help        Display this help message."
  echo ""
}

compare_versions() {
  local v1="${1#v}"
  local v2="${2#v}"

  if [[ "$v1" == N/A* || "$v1" == ERR_* || "$v1" == TIMEOUT_* || "$v1" == HTTP_* ]]; then return 3; fi
  if [[ "$v2" == N/A* || "$v2" == ERR_* || "$v2" == NO_RELEASES ]]; then return 3; fi

  if [[ "$v1" == "$v2" ]]; then return 0; fi

  local sorted_first
  sorted_first=$(printf '%s\n%s\n' "$v1" "$v2" | sort -V 2>/dev/null | head -n 1)

  if [[ -z "$sorted_first" || (""$sorted_first"" != ""$v1"" && ""$sorted_first"" != ""$v2"") ]]; then
    if [[ "$v1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-.+)?$ && "$v2" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-.+)?$ ]]; then
      return 3
    fi
    return 3
  fi

  if [[ "$sorted_first" == "$v1" ]]; then
    return 2
  else
    return 1
  fi
}

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
  GITHUB_RELEASE_CACHE_TTL_SECONDS=$(yq e '.global.github_release_cache_ttl_seconds // "0"' "$CONFIG_FILE_TO_USE")

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
  mapfile -t SELECTED_TENANTS < <(yq e '.defaults.tenants[] // "all"' "$CONFIG_FILE_TO_USE")
  mapfile -t SELECTED_ENVIRONMENTS < <(yq e '.defaults.environments[] // "all"' "$CONFIG_FILE_TO_USE")
  mapfile -t SELECTED_REGIONS < <(yq e '.defaults.regions[] // "all"' "$CONFIG_FILE_TO_USE")
  mapfile -t SELECTED_SERVICES < <(yq e '.defaults.services[] // "all"' "$CONFIG_FILE_TO_USE")

  SELECTED_TENANTS=($(echo "${SELECTED_TENANTS[@]}" | xargs))
  SELECTED_ENVIRONMENTS=($(echo "${SELECTED_ENVIRONMENTS[@]}" | xargs))
  SELECTED_REGIONS=($(echo "${SELECTED_REGIONS[@]}" | xargs))
  SELECTED_SERVICES=($(echo "${SELECTED_SERVICES[@]}" | xargs))

  SELECTED_TENANTS=($(echo "${SELECTED_TENANTS[@]}" | tr ' ' '\n' | grep -vE '^\s*$|null' | sort -u | xargs))
  SELECTED_ENVIRONMENTS=($(echo "${SELECTED_ENVIRONMENTS[@]}" | tr ' ' '\n' | grep -vE '^\s*$|null' | sort -u | xargs))
  SELECTED_REGIONS=($(echo "${SELECTED_REGIONS[@]}" | tr ' ' '\n' | grep -vE '^\s*$|null' | sort -u | xargs))
  SELECTED_SERVICES=($(echo "${SELECTED_SERVICES[@]}" | tr ' ' '\n' | grep -vE '^\s*$|null' | sort -u | xargs))

  if [[ "${SELECTED_TENANTS[*]}" =~ (^| )all( |$) ]]; then SELECTED_TENANTS=("all"); fi
  if [[ "${SELECTED_ENVIRONMENTS[*]}" =~ (^| )all( |$) ]]; then SELECTED_ENVIRONMENTS=("all"); fi
  if [[ "${SELECTED_REGIONS[*]}" =~ (^| )all( |$) ]]; then SELECTED_REGIONS=("all"); fi
  if [[ "${SELECTED_SERVICES[*]}" =~ (^| )all( |$) ]]; then SELECTED_SERVICES=("all"); fi

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
    if yq e ".services_repo_map | has(\"$key\")" "$CONFIG_FILE_TO_USE" | grep -q "true"; then
      SERVICES_REPO_MAP_DATA["$key,display_name"]=$(yq e ".services_repo_map[\"$key\"].display_name // \"$key\"" "$CONFIG_FILE_TO_USE")
      SERVICES_REPO_MAP_DATA["$key,repo"]=$(yq e ".services_repo_map[\"$key\"].repo" "$CONFIG_FILE_TO_USE")
      SERVICES_REPO_MAP_DATA["$key,url_param_default"]=$(yq e ".services_repo_map[\"$key\"].url_param_default // \"$key\"" "$CONFIG_FILE_TO_USE")

      if [[ -z "${SERVICES_REPO_MAP_DATA["$key,repo"]}" || "${SERVICES_REPO_MAP_DATA["$key,repo"]}" == "null" ]]; then
        log_error "Service key '$key' in services_repo_map is missing 'repo' information or it is null."
        exit 1
      fi
    else
      log_error "Service key '$key' found in keys but not as a map entry? Skipping."
    fi
  done
}

get_latest_github_release_tags() {
  local repo_name="$1"
  local limit="${2:-1}"
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
      log_error "GitHub repository not found: $repo_name"
      echo "ERR_GH_NOT_FOUND"
    elif echo "$gh_stderr_output" | grep -q -i "No releases found"; then
      log_debug "No releases found for repository: $repo_name"
      echo "NO_RELEASES"
    else
      log_error "gh CLI error for $repo_name (limit $limit): $gh_stderr_output"
      echo "ERR_GH_CLI($gh_status)"
    fi
    return 1
  fi
  if [[ -z "$release_tags_str" ]]; then
    log_debug "gh release list returned empty output for $repo_name."
    echo "NO_RELEASES"
    return 1
  fi
  echo "$release_tags_str"
  return 0
}

get_cached_or_fetch_latest_gh_release() {
  local repo_name="$1"
  local cache_file_tag="$CACHE_DIR/$GH_CACHE_SUBDIR/gh_release_tag_${repo_name//\//_}.txt"
  local cache_ts_file="$CACHE_DIR/$GH_CACHE_SUBDIR/gh_release_ts_${repo_name//\//_}.txt"
  local current_time
  current_time=$(date +%s)
  local release_tag="N/A_GH_FETCH"

  if [[ -v GITHUB_LATEST_VERSION_CACHE["$repo_name"] ]]; then
    log_debug "GH release cache HIT (in-memory) for $repo_name"
    echo "${GITHUB_LATEST_VERSION_CACHE["$repo_name"]}"
    return 0
  fi

  if [[ -f "$cache_file_tag" && -f "$cache_ts_file" ]]; then
    local cache_ts
    cache_ts=$(cat "$cache_ts_file")
    if [[ "$GITHUB_RELEASE_CACHE_TTL_SECONDS" -gt 0 ]] && ((current_time - cache_ts < GITHUB_RELEASE_CACHE_TTL_SECONDS)); then
      release_tag=$(cat "$cache_file_tag")
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

  release_tag="${latest_tags[0]}"

  if [[ "$fetch_status" -ne 0 ]]; then
    :
  elif [[ -z "$release_tag" ]]; then
    release_tag="NO_RELEASES"
  else
    echo "$release_tag" >"$cache_file_tag"
    echo "$current_time" >"$cache_ts_file"
    log_debug "Cached GH release '$release_tag' for $repo_name"
  fi

  GITHUB_LATEST_VERSION_CACHE["$repo_name"]="$release_tag"
  echo "$release_tag"
}

get_deployed_version() {
  local service_url_param="$1" region_url_param_for_url="$2" effective_tenant="$3" effective_env="$4" jq_query="$5"
  local url="$SERVICE_URL_TEMPLATE"
  url="${url//\{service_url_param\}/$service_url_param}"
  url="${url//\{region_url_param\}/$region_url_param_for_url}"
  url="${url//\{effective_tenant\}/$effective_tenant}"
  url="${url//\{effective_env\}/$effective_env}"

  log_verbose "Fetching version from: $url"

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

run_interactive_config() {
  CONFIG_FILE_TO_USE="${CONFIG_FILE_CMD_OPT:-$DEFAULT_CONFIG_FILE}"
  log_info "Starting interactive configuration using gum..."

  local all_tenants=($(yq e '.targets[].tenant' "$CONFIG_FILE_TO_USE" | sort -u | xargs))
  local all_environments=($(yq e '.targets[].environment' "$CONFIG_FILE_TO_USE" | sort -u | xargs))
  local all_regions=($(yq e '.targets[].region_url_param' "$CONFIG_FILE_TO_USE" | sort -u | xargs))
  local all_service_keys=($(yq e '.services_repo_map | keys | .[]' "$CONFIG_FILE_TO_USE" | sort -u | xargs))
  local all_service_display_names=()
  for skey in "${all_service_keys[@]}"; do
    local display_name="${SERVICES_REPO_MAP_DATA["$skey,display_name"]:-$skey}"
    all_service_display_names+=("$display_name ($skey)")
  done

  if [[ ${#all_tenants[@]} -gt 0 ]]; then all_tenants=("all" "${all_tenants[@]}"); fi
  if [[ ${#all_environments[@]} -gt 0 ]]; then all_environments=("all" "${all_environments[@]}"); fi
  if [[ ${#all_regions[@]} -gt 0 ]]; then all_regions=("all" "${all_regions[@]}"); fi

  if [[ ${#all_tenants[@]} -gt 0 ]]; then
    echo "Select tenants to query (current defaults: ${SELECTED_TENANTS[*]}):"
    mapfile -t SELECTED_TENANTS_GUM < <(gum choose --no-limit "${all_tenants[@]}")
    if [[ ${#SELECTED_TENANTS_GUM[@]} -gt 0 ]]; then SELECTED_TENANTS=("${SELECTED_TENANTS_GUM[@]}"); fi
  fi

  if [[ ${#all_environments[@]} -gt 0 ]]; then
    echo "Select environments to query (current defaults: ${SELECTED_ENVIRONMENTS[*]}):"
    mapfile -t SELECTED_ENVIRONMENTS_GUM < <(gum choose --no-limit "${all_environments[@]}")
    if [[ ${#SELECTED_ENVIRONMENTS_GUM[@]} -gt 0 ]]; then SELECTED_ENVIRONMENTS=("${SELECTED_ENVIRONMENTS_GUM[@]}"); fi
  fi

  if [[ "$REGION_FILTER_MODE" == "off" ]]; then
    log_info "Region filter mode: '$REGION_FILTER_MODE'. Region selection below sets default for '--config' mode, but will NOT filter targets in 'off' mode (queries one instance per service/tenant/env combo)."
    if [[ ${#all_regions[@]} -gt 0 ]]; then
      mapfile -t SELECTED_REGIONS_GUM < <(gum choose --no-limit "${all_regions[@]}")
      if [[ ${#SELECTED_REGIONS_GUM[@]} -eq 0 ]]; then
        log_debug "Interactive region selection was empty. Defaulting SELECTED_REGIONS filter variable to 'all'."
        SELECTED_REGIONS=("all")
      else
        SELECTED_REGIONS=("${SELECTED_REGIONS_GUM[@]}")
      fi
    else
      log_info "No regions found in config for interactive selection. Defaulting SELECTED_REGIONS filter variable to 'all'."
      SELECTED_REGIONS=("all")
    fi
  else
    log_info "Region selection via gum skipped because -r '$USER_SPECIFIED_REGION_VALUE' was used (mode '$REGION_FILTER_MODE')."
  fi

  if [[ ${#all_service_display_names[@]} -gt 0 ]]; then
    echo "Select services to query (current defaults: ${SELECTED_SERVICES[*]}):"
    mapfile -t selected_display_names < <(gum choose --no-limit "${all_service_display_names[@]}")
    if [[ ${#selected_display_names[@]} -gt 0 ]]; then
      SELECTED_SERVICES=()
      for display_name_with_key in "${selected_display_names[@]}"; do
        local skey_from_display=${display_name_with_key##*$$}
        skey_from_display=${skey_from_display%$$*}
        SELECTED_SERVICES+=("$skey_from_display")
      done
    else
      log_info "No services selected interactively. Using default services: ${SELECTED_SERVICES[*]}."
    fi
  fi

  local effective_selected_services=("${SELECTED_SERVICES[@]}")
  if [[ "${effective_selected_services[0]}" == "all" ]]; then
    effective_selected_services=($(yq e '.services_repo_map | keys | .[]' "$CONFIG_FILE_TO_USE" | xargs))
  fi

  if [[ ${#effective_selected_services[@]} -gt 0 ]]; then
    for service_key_to_configure in "${effective_selected_services[@]}"; do
      if [[ -v SERVICES_REPO_MAP_DATA["$service_key_to_configure,repo"] ]]; then
        local repo_for_service="${SERVICES_REPO_MAP_DATA["$service_key_to_configure,repo"]}"
        local display_name_for_service="${SERVICES_REPO_MAP_DATA["$service_key_to_configure,display_name"]:-$service_key_to_configure}"

        echo "Fetching 5 latest releases for $display_name_for_service ($repo_for_service)..."
        mapfile -t latest_5_tags < <(get_latest_github_release_tags "$repo_for_service" 5)

        if [[ "${latest_5_tags[0]}" == ERR_* || "${latest_5_tags[0]}" == "NO_RELEASES" || ${#latest_5_tags[@]} -eq 0 ]]; then
          log_error "Could not fetch releases or no releases found for $display_name_for_service. Will use 'latest' logic for comparison."
          USER_SELECTED_GH_VERSIONS["$service_key_to_configure"]="latest"
          continue
        fi

        local gum_options=("Use latest GitHub release (auto)" "${latest_5_tags[@]}")
        echo "Choose GitHub version for comparison for $display_name_for_service:"
        chosen_version=$(gum choose "${gum_options[@]}")

        if [[ "$chosen_version" == "Use latest GitHub release (auto)" || -z "$chosen_version" ]]; then
          USER_SELECTED_GH_VERSIONS["$service_key_to_configure"]="latest"
        else
          USER_SELECTED_GH_VERSIONS["$service_key_to_configure"]="$chosen_version"
        fi
      else
        log_error "Service key '$service_key_to_configure' selected but not found in services_repo_map. Skipping GH version selection for this service."
        USER_SELECTED_GH_VERSIONS["$service_key_to_configure"]="latest"
      fi
    done
  else
    log_info "No services configured in config. Skipping GitHub version selection."
  fi
  log_info "Interactive configuration complete."
}

process_target() {
  local target_json="$1"

  local target_name service_key environment tenant region_url_param service_url_param_override
  target_name=$(echo "$target_json" | jq -r '.name // "Unnamed Target"')
  service_key=$(echo "$target_json" | jq -r '.service_key')
  environment=$(echo "$target_json" | jq -r '.environment')
  tenant=$(echo "$target_json" | jq -r '.tenant')
  region_url_param=$(echo "$target_json" | jq -r '.region_url_param // "null"')
  service_url_param_override=$(echo "$target_json" | jq -r '.service_url_param_override // ""')

  if [[ ! -v SERVICES_REPO_MAP_DATA["$service_key,repo"] ]]; then
    log_error "Target '$target_name' refers to unknown service_key '$service_key'. Skipping."
    echo "$target_name|N/A_UNKNOWN_SVC|N/A_UNKNOWN_SVC|${RED}UNKNOWN_SERVICE${NC}|Unknown Service ($service_key)|$tenant|$environment|$region_url_param|UNKNOWN_SERVICE"
    return 1
  fi

  local service_repo="${SERVICES_REPO_MAP_DATA["$service_key,repo"]}"
  local service_display_name="${SERVICES_REPO_MAP_DATA["$service_key,display_name"]:-$service_key}"
  local service_url_param_default="${SERVICES_REPO_MAP_DATA["$service_key,url_param_default"]:-$service_key}"
  local effective_service_url_param="$service_url_param_default"
  if [[ -n "$service_url_param_override" && "$service_url_param_override" != "null" ]]; then
    effective_service_url_param="$service_url_param_override"
  fi

  local github_reference_version
  if [[ -v USER_SELECTED_GH_VERSIONS["$service_key"] && "${USER_SELECTED_GH_VERSIONS["$service_key"]}" != "latest" ]]; then
    github_reference_version="${USER_SELECTED_GH_VERSIONS["$service_key"]}"
    log_debug "Using user-selected GH version ${github_reference_version} for $service_key"
  elif [[ -v USER_SELECTED_GH_VERSIONS["$service_key"] && "${USER_SELECTED_GH_VERSIONS["$service_key"]}" == "latest" ]]; then
    github_reference_version=$(get_cached_or_fetch_latest_gh_release "$service_repo")
    log_debug "Using latest GH version ${github_reference_version} (cached or fetched) for $service_key"
  else
    log_debug "No GH version specified for $service_key, defaulting to latest."
    github_reference_version=$(get_cached_or_fetch_latest_gh_release "$service_repo")
  fi

  local region_url_param_for_curl="$region_url_param"
  if [[ "$REGION_FILTER_MODE" == "off" ]]; then
    log_debug "REGION_FILTER_MODE is 'off'. Setting region_url_param_for_curl to empty string for URL construction."
    region_url_param_for_curl=""
  fi

  local deployed_version
  deployed_version=$(get_deployed_version "$effective_service_url_param" "$region_url_param_for_curl" "$tenant" "$environment" "$DEFAULT_VERSION_JQ_QUERY")

  local status_text raw_status_text
  if [[ "$github_reference_version" == ERR_GH* || "$github_reference_version" == "N/A_GH_FETCH" ]]; then
    status_text="${RED}${github_reference_version}${NC}"
    raw_status_text="GH_ERROR"
  elif [[ "$github_reference_version" == "NO_RELEASES" ]]; then
    status_text="${CYAN}NO_GH_RELEASES${NC}"
    raw_status_text="NO_RELEASES"
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
      ;;
    2)
      status_text="${YELLOW}OUTDATED${NC}"
      raw_status_text="OUTDATED"
      ;;
    *)
      status_text="${YELLOW}CMP_ERR ($deployed_version vs $github_reference_version)${NC}"
      raw_status_text="UNKNOWN_CMP"
      ;;
    esac
  fi

  echo "$target_name|$deployed_version|$github_reference_version|$status_text|$service_display_name|$tenant|$environment|$region_url_param|$raw_status_text"
  return 0
}
main() {
  INTERACTIVE_CONFIG_MODE=false
  while getopts ":f:cvr:h" opt; do
    case $opt in
    f) CONFIG_FILE_CMD_OPT="$OPTARG" ;;
    c) INTERACTIVE_CONFIG_MODE=true ;;
    v) VERBOSE=true ;;
    r)
      USER_SPECIFIED_REGION_VALUE="$OPTARG"
      case "$USER_SPECIFIED_REGION_VALUE" in
      off | primary | secondary | all) REGION_FILTER_MODE="$USER_SPECIFIED_REGION_VALUE" ;;
      *)
        log_error "Invalid region mode: '$USER_SPECIFIED_REGION_VALUE'. Allowed modes: 'off', 'primary', 'secondary', 'all'."
        print_usage
        exit 1
        ;;
      esac
      ;;
    h)
      print_usage
      exit 0
      ;;
    \?)
      log_error "Invalid option: -$OPTARG"
      print_usage
      exit 1
      ;;
    :)
      log_error "Option -$OPTARG requires an argument."
      print_usage
      exit 1
      ;;
    esac
  done
  shift $((OPTIND - 1))

  check_deps
  parse_global_config
  parse_services_repo_map
  parse_defaults_from_config

  if $INTERACTIVE_CONFIG_MODE; then
    run_interactive_config
  else
    log_info "Using default filters from config."
    local all_configured_service_keys=($(yq e '.services_repo_map | keys | .[]' "$CONFIG_FILE_TO_USE" | xargs))
    for skey in "${all_configured_service_keys[@]}"; do
      if [[ ! -v USER_SELECTED_GH_VERSIONS["$skey"] ]]; then
        USER_SELECTED_GH_VERSIONS["$skey"]="latest"
      fi
    done
    log_info "Version comparison will use latest GitHub release for services not specifically configured (default)."
  fi

  CONFIG_FILE_TO_USE="${CONFIG_FILE_CMD_OPT:-$DEFAULT_CONFIG_FILE}"
  local all_targets_json
  all_targets_json=$(yq e -o=json '.targets' "$CONFIG_FILE_TO_USE")
  if [[ -z "$all_targets_json" || "$all_targets_json" == "null" || "$(echo "$all_targets_json" | jq 'length')" == "0" ]]; then
    log_error "No targets found in $CONFIG_FILE_TO_USE or error parsing targets."
    exit 1
  fi

  declare -a final_filtered_targets_json_array=()
  local num_all_targets
  num_all_targets=$(echo "$all_targets_json" | jq 'length')

  declare -A service_tenant_env_selection_tracker

  log_info "Filter criteria: Tenants=[${SELECTED_TENANTS[*]}], Envs=[${SELECTED_ENVIRONMENTS[*]}], Services=[${SELECTED_SERVICES[*]}]"
  log_info "Region mode: '$REGION_FILTER_MODE'."
  if [[ "$REGION_FILTER_MODE" == "off" ]]; then
    log_info "Region filtering is OFF. Querying only the FIRST instance encountered for each unique service/tenant/env combo. Region URL parameter will be empty for CURL."
  else
    log_info "Region filtering/selection is active based on mode '$REGION_FILTER_MODE'."
  fi

  for i in $(seq 0 $((num_all_targets - 1))); do
    local current_target_json
    current_target_json=$(echo "$all_targets_json" | jq -c ".[$i]")
    local t_tenant t_env t_region t_service_key t_name
    t_name=$(echo "$current_target_json" | jq -r '.name // "Unnamed Target"')
    t_tenant=$(echo "$current_target_json" | jq -r '.tenant // "null"')
    t_env=$(echo "$current_target_json" | jq -r '.environment // "null"')
    t_region=$(echo "$current_target_json" | jq -r '.region_url_param // "null"')
    t_service_key=$(echo "$current_target_json" | jq -r '.service_key // "null"')

    if [[ "$t_service_key" == "null" || "$t_tenant" == "null" || "$t_env" == "null" || "$t_region" == "null" ]]; then
      log_debug "Skipping target '$t_name' (index $i) due to missing service_key, tenant, environment, or region_url_param."
      continue
    fi

    if [[ ! -v SERVICES_REPO_MAP_DATA["$t_service_key,repo"] ]]; then
      log_debug "Skipping target '$t_name' (index $i) with unknown service_key '$t_service_key'."
      continue
    fi

    local tenant_match=false env_match=false service_match=false
    if [[ "${SELECTED_TENANTS[0]}" == "all" || " ${SELECTED_TENANTS[*]} " =~ " $t_tenant " ]]; then tenant_match=true; fi
    if [[ "${SELECTED_ENVIRONMENTS[0]}" == "all" || " ${SELECTED_ENVIRONMENTS[*]} " =~ " $t_env " ]]; then env_match=true; fi
    if [[ "${SELECTED_SERVICES[0]}" == "all" || " ${SELECTED_SERVICES[*]} " =~ " $t_service_key " ]]; then service_match=true; fi

    if ! $tenant_match || ! $env_match || ! $service_match; then
      log_debug "Skipping target '$t_name' (index $i): Failed tenant/env/service filter (Tenant:$tenant_match, Env:$env_match, Service:$service_match)."
      continue
    fi

    local region_selection_passed=false
    local count_key="${t_service_key}-${t_tenant}-${t_env}"

    case "$REGION_FILTER_MODE" in
    off)
      if ((service_tenant_env_selection_tracker["$count_key"] == 0)); then
        region_selection_passed=true
        service_tenant_env_selection_tracker["$count_key"]=1
        log_debug "Target '$t_name' (index $i) passed region selection (mode 'off', first instance for combo '$count_key')."
      else
        log_debug "Skipping target '$t_name' (index $i): Already selected an instance for combo '$count_key' (mode 'off')."
        region_selection_passed=false
      fi
      ;;
    all)
      region_selection_passed=true
      log_debug "Target '$t_name' (index $i) passed region filter (mode 'all')."
      ;;
    primary | secondary)
      service_tenant_env_selection_tracker["$count_key"]=$((service_tenant_env_selection_tracker["$count_key"] + 1))
      local current_instance_number=${service_tenant_env_selection_tracker["$count_key"]}

      if [[ "$REGION_FILTER_MODE" == "primary" && "$current_instance_number" -eq 1 ]]; then
        region_selection_passed=true
        log_debug "Target '$t_name' (index $i) passed region selection (mode 'primary', instance #$current_instance_number)."
      elif [[ "$REGION_FILTER_MODE" == "secondary" && "$current_instance_number" -eq 2 ]]; then
        region_selection_passed=true
        log_debug "Target '$t_name' (index $i) passed region selection (mode 'secondary', instance #$current_instance_number)."
      else
        log_debug "Skipping target '$t_name' (index $i): Instance #$current_instance_number for $count_key does not match region_mode '$REGION_FILTER_MODE'."
        region_selection_passed=false
      fi
      ;;
    esac

    if $region_selection_passed; then
      log_debug "Including target '$t_name' (index $i) for processing."
      final_filtered_targets_json_array+=("$current_target_json")
    fi
  done

  local num_filtered_targets=${#final_filtered_targets_json_array[@]}
  if [[ "$num_filtered_targets" -eq 0 ]]; then
    log_info "No targets match the current filter criteria. Exiting."
    exit 0
  fi
  log_info "Processing $num_filtered_targets targets sequentially (out of $num_all_targets total targets parsed from config)."

  declare -a results_array=0
  for i in $(seq 0 $((num_filtered_targets - 1))); do
    local target_item_json="${final_filtered_targets_json_array[$i]}"
    local target_name_for_progress
    target_name_for_progress=$(echo "$target_item_json" | jq -r '.name // "Unknown Target"')
    printf "\rProcessing target %s/%s: %s..." "$((i + 1))" "$num_filtered_targets" "$target_name_for_progress" >&2

    local result_line
    result_line=$(process_target "$target_item_json")
    local process_status=$?
    if [[ $process_status -eq 0 && -n "$result_line" ]]; then
      results_array[0]=$((results_array[0] + 1))
      results_array+=("$result_line")
    else
      log_debug "Process_target failed for '$target_name_for_progress' (index $i), status $process_status."
    fi
  done

  printf "\n" >&2

  local num_successful_results=${results_array[0]}
  unset results_array[0]

  if [[ "$num_successful_results" -eq 0 ]]; then
    log_info "No successful results to report after processing."
    exit 0
  fi

  log_info "All eligible targets processed. Generating report..."

  local max_name_len=55
  local max_deployed_len=10
  local max_latest_len=12
  local max_service_len=40
  local max_tenant_len=7
  local max_env_len=5
  local max_region_len=10

  for line in "${results_array[@]}"; do
    local fields=($(echo "$line" | awk -F'|' '{gsub(/\x1B\[[0-9;]*m/, ""); print $1, $2, $3, $5, $6, $7, $8}'))
    local name="${fields[0]}" deployed="${fields[1]}" latest="${fields[2]}" service="${fields[3]}" tenant="${fields[4]}" env="${fields[5]}" region="${fields[6]}"

    ((${#name} > max_name_len)) && max_name_len=${#name}
    ((${#deployed} > max_deployed_len)) && max_deployed_len=${#deployed}
    ((${#latest} > max_latest_len)) && max_latest_len=${#latest}
    ((${#service} > max_service_len)) && max_service_len=${#service}
    ((${#tenant} > max_tenant_len)) && max_tenant_len=${#tenant}
    ((${#env} > max_env_len)) && max_env_len=${#env}
    ((${#region} > max_region_len)) && max_region_len=${#region}
  done
  max_name_len=$((max_name_len + 2))
  max_deployed_len=$((max_deployed_len + 2))
  max_latest_len=$((max_latest_len + 2))
  max_service_len=$((max_service_len + 2))
  max_tenant_len=$((max_tenant_len + 2))
  max_env_len=$((max_env_len + 2))
  max_region_len=$((max_region_len + 2))

  local format_string="%-*s | %-*s | %-*s | %-*s | %-*s | %-*s | %-*s | %s\n"
  printf "\n--- Service Version Status (Generated: $(date)) ---\n"
  printf "$format_string" \
    "$max_service_len" "Service" "$max_tenant_len" "Tenant" "$max_env_len" "Env" "$max_region_len" "Region" \
    "$max_name_len" "Target Instance" "$max_deployed_len" "Deployed" "$max_latest_len" "GH Ref Ver" "Status"

  local separator_len=$((max_service_len + max_tenant_len + max_env_len + max_region_len + max_name_len + max_deployed_len + max_latest_len + 7 * 3))
  printf "%${separator_len}s\n" "" | tr " " "-"

  declare -a sorted_results=()
  while IFS= read -r line; do sorted_results+=("$line"); done < <(
    printf "%s\n" "${results_array[@]}" |
      awk -F'|' '
      function status_sort_key(status) {
          if (status == "GH_ERROR") return 1;
          if (status == "SVC_ERROR") return 2;
          if (status == "AHEAD") return 3;
          if (status == "OUTDATED") return 4;
          if (status == "NO_GH_RELEASES") return 5;
          if (status == "UP-TO-DATE") return 6;
          return 7;
      }
      { print status_sort_key($9) "|" $0 }' |
      sort -t'|' -k1,1n -k6,6 -k7,7 -k5,5 -k8,8 | cut -d'|' -f2-
  )

  for line in "${sorted_results[@]}"; do
    local target_name_val deployed_val gh_ref_ver_val status_val service_val tenant_val env_val region_val _
    IFS='|' read -r target_name_val deployed_val gh_ref_ver_val status_val service_val tenant_val env_val region_val _ <<<"$line"
    printf "$format_string" \
      "$max_service_len" "$service_val" "$max_tenant_len" "$tenant_val" "$max_env_len" "$env_val" "$max_region_len" "$region_val" \
      "$max_name_len" "$target_name_val" "$max_deployed_len" "$deployed_val" "$max_latest_len" "$gh_ref_ver_val" "$status_val"
  done

  log_info "Cleaning up temporary directory: $TMP_DIR" >&2
  if [[ -n "$TMP_DIR" ]] && [[ "$TMP_DIR" == /tmp/version_checker_* ]] && [[ -d "$TMP_DIR" ]]; then
    log_debug "Removing $TMP_DIR..." >&2
    rm -rf "$TMP_DIR"
  else
    log_debug "Cleanup skipped for TMP_DIR: '$TMP_DIR' (either empty, unexpected pattern, or non-existent)." >&2
  fi
}

cleanup() {
  if [[ -n "$TMP_DIR" ]] && [[ "$TMP_DIR" == /tmp/version_checker_* ]] && [[ -d "$TMP_DIR" ]]; then
    log_info "Script interrupted/finished. Cleaning up $TMP_DIR..." >&2
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT SIGINT SIGTERM

main "$@"
