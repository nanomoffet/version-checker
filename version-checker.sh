#!/usr/bin/env zsh

# Script to check deployed service versions against GitHub releases
#
# Dependencies: yq, jq, curl, gh

# --- Configuration ---
CONFIG_FILE="${1:-config.yaml}"
TMP_DIR="/tmp/version_checker_$$"
CACHE_DIR="$HOME/.cache/version_checker"
mkdir -p "$TMP_DIR"
mkdir -p "$CACHE_DIR"

# --- Helper Functions ---

log_error() {
  echo "ERROR: $1" >&2
}

log_info() {
  echo "INFO: $1"
}

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check for required tools
check_deps() {
  local missing_deps=0
  for cmd_tool in yq jq curl gh; do
    if ! command -v "$cmd_tool" &> /dev/null; then
      log_error "Required command '$cmd_tool' not found. Please install it."
      missing_deps=1
    fi
  done

  if command -v gh &> /dev/null; then
    if ! gh auth status &>/dev/null; then
      log_error "GitHub CLI ('gh') is installed but not authenticated. Please run 'gh auth login'."
      missing_deps=1
    fi
  fi

  if [[ "$missing_deps" -eq 1 ]]; then
    exit 1
  fi
}

# --- Global Variables from Config ---
DEFAULT_CURL_TIMEOUT_SECONDS=""
MAX_PARALLEL_JOBS=""
GITHUB_RELEASE_CACHE_TTL_SECONDS=""
DEFAULT_VERSION_JQ_QUERY=""
SERVICE_URL_TEMPLATE=""

# Associative array to store service repo details
typeset -A SERVICES_REPO_MAP_DATA

# Associative array for GitHub release cache (in-memory for current script run)
typeset -A GITHUB_LATEST_VERSION_CACHE

# --- YAML Parsing Functions ---

parse_global_config() {
  log_info "Parsing global configuration..."
  DEFAULT_CURL_TIMEOUT_SECONDS=$(yq e '.global.default_curl_timeout_seconds' "$CONFIG_FILE")
  MAX_PARALLEL_JOBS=$(yq e '.global.max_parallel_jobs' "$CONFIG_FILE")
  GITHUB_RELEASE_CACHE_TTL_SECONDS=$(yq e '.global.github_release_cache_ttl_seconds' "$CONFIG_FILE")
  DEFAULT_VERSION_JQ_QUERY=$(yq e '.global.default_version_jq_query' "$CONFIG_FILE")
  SERVICE_URL_TEMPLATE=$(yq e '.global.service_url_template' "$CONFIG_FILE")

  if [[ -z "$DEFAULT_CURL_TIMEOUT_SECONDS" || -z "$MAX_PARALLEL_JOBS" || -z "$GITHUB_RELEASE_CACHE_TTL_SECONDS" || -z "$DEFAULT_VERSION_JQ_QUERY" || -z "$SERVICE_URL_TEMPLATE" ]]; then
    log_error "One or more global configuration values are missing from $CONFIG_FILE"
    exit 1
  fi
}

parse_services_repo_map() {
  log_info "Parsing services_repo_map..."
  local service_keys
  service_keys=($(yq e '.services_repo_map | keys | .[]' "$CONFIG_FILE"))

  for key in "${service_keys[@]}"; do
    SERVICES_REPO_MAP_DATA["$key,display_name"]=$(yq e ".services_repo_map.$key.display_name" "$CONFIG_FILE")
    SERVICES_REPO_MAP_DATA["$key,repo"]=$(yq e ".services_repo_map.$key.repo" "$CONFIG_FILE")
    SERVICES_REPO_MAP_DATA["$key,url_param_default"]=$(yq e ".services_repo_map.$key.url_param_default" "$CONFIG_FILE")
  done
}

# --- Data Fetching Functions ---

get_latest_github_release() {
  local repo_name="$1"
  # Cache file now stores the tag directly, not full JSON
  local cache_file_tag="$CACHE_DIR/gh_release_tag_${repo_name//\//_}.txt"
  local cache_ts_file="$CACHE_DIR/gh_release_ts_${repo_name//\//_}.txt" # Renamed for clarity
  local current_time=$(date +%s)
  local release_tag="N/A_GH_FETCH"

  # Check file cache
  if [[ -f "$cache_file_tag" && -f "$cache_ts_file" ]]; then
    local cache_ts=$(cat "$cache_ts_file")
    if (( (current_time - cache_ts) < GITHUB_RELEASE_CACHE_TTL_SECONDS )); then
      release_tag=$(cat "$cache_file_tag")
      if [[ -z "$release_tag" ]]; then # Should ideally not happen if written correctly
          release_tag="ERR_GH_CACHE_EMPTY" # Mark as error to force refetch
      else
          # log_info "Cache hit for $repo_name: $release_tag (File Cache)" # Optional: for debugging
          echo "$release_tag"
          return 0
      fi
    fi
  fi

  # Fetch from GitHub CLI
  local gh_response_json
  local gh_stderr_file="$TMP_DIR/gh_stderr_${repo_name//\//_}_$$.txt" # Unique stderr file

  # Using process substitution for stderr doesn't work well with checking $? immediately after for gh
  gh_response_json=$(gh release list --repo "${repo_name}" --limit 1 --json tagName 2> "$gh_stderr_file")
  local gh_status=$?
  local gh_stderr_output=""
  if [[ -f "$gh_stderr_file" ]]; then
    gh_stderr_output=$(cat "$gh_stderr_file")
    rm -f "$gh_stderr_file"
  fi

  if [[ $gh_status -ne 0 ]]; then
    if echo "$gh_stderr_output" | grep -q -i "Could not resolve to a Repository"; then
      release_tag="ERR_GH_NOT_FOUND"
    elif echo "$gh_stderr_output" | grep -q -i "authentication required"; then
      release_tag="ERR_GH_AUTH" # Should be caught by check_deps, but good to have specific error
    elif echo "$gh_stderr_output" | grep -q -i "No releases found"; then # Some versions of gh might output this to stderr
      release_tag="NO_RELEASES"
    else
      log_error "gh CLI error for $repo_name (status $gh_status): $gh_stderr_output"
      release_tag="ERR_GH_CLI($gh_status)"
    fi
  else
    # gh command succeeded, parse the JSON
    # Output is like: [{"tagName":"v1.2.3"}] or [] if no releases
    release_tag=$(echo "$gh_response_json" | jq -r '.[0].tagName // "NO_RELEASES_JQ"')
    if [[ "$release_tag" == "NO_RELEASES_JQ" || -z "$release_tag" || "$release_tag" == "null" ]]; then
      release_tag="NO_RELEASES"
    fi
  fi

  # Update file cache if we got a definitive answer (a tag or NO_RELEASES)
  if [[ "$release_tag" != ERR_* && "$release_tag" != "N/A_GH_FETCH" ]]; then
    echo "$release_tag" > "$cache_file_tag"
    echo "$current_time" > "$cache_ts_file"
  fi

  echo "$release_tag"
}


get_deployed_version() {
  local service_url_param="$1"
  local region_url_param="$2"
  local effective_tenant="$3"
  local effective_env="$4"
  local jq_query="$5"

  local url="$SERVICE_URL_TEMPLATE"
  url="${url//\{service_url_param\}/$service_url_param}"
  url="${url//\{region_url_param\}/$region_url_param}"
  url="${url//\{effective_tenant\}/$effective_tenant}"
  url="${url//\{effective_env\}/$effective_env}"

  local deployed_version="N/A_DEPLOY_FETCH"
  local response
  response=$(curl --max-time "$DEFAULT_CURL_TIMEOUT_SECONDS" -s -L "$url") # -L for redirects
  local http_status=$? # curl exit code

  if [[ $http_status -ne 0 ]]; then
    if [[ $http_status -eq 28 ]]; then # Timeout
        deployed_version="TIMEOUT_SVC"
    else
        deployed_version="ERR_SVC_CURL($http_status)"
    fi
  else
    deployed_version=$(echo "$response" | jq -r "$jq_query" 2>/dev/null)
    if [[ -z "$deployed_version" || "$deployed_version" == "null" ]]; then
      local http_code_from_json=$(echo "$response" | jq -r '.statusCode // .status // ""' 2>/dev/null)
      if [[ -n "$http_code_from_json" && "$http_code_from_json" != "null" ]]; then
        deployed_version="HTTP_$http_code_from_json"
      else
        # Check if the response is an HTML error page or non-JSON
        if echo "$response" | grep -q -iE '<html>|<head>|Error'; then
            deployed_version="ERR_SVC_HTML_RESP"
        else
            deployed_version="ERR_SVC_PARSE"
        fi
      fi
    fi
  fi
  echo "$deployed_version"
}

# --- Main Processing Function for Each Target ---
process_target() {
  local target_index="$1"
  local target_json="$2"
  local target_result_file="$TMP_DIR/result_${target_index}.txt"

  local target_name=$(echo "$target_json" | jq -r '.name')
  local service_key=$(echo "$target_json" | jq -r '.service_key')
  local environment=$(echo "$target_json" | jq -r '.environment')
  local tenant=$(echo "$target_json" | jq -r '.tenant') # This is effective_tenant
  local region_url_param=$(echo "$target_json" | jq -r '.region_url_param')
  local service_url_param_override=$(echo "$target_json" | jq -r '.service_url_param_override // ""')

  local service_repo="${SERVICES_REPO_MAP_DATA[$service_key,repo]}"
  local service_display_name="${SERVICES_REPO_MAP_DATA[$service_key,display_name]}"
  local service_url_param_default="${SERVICES_REPO_MAP_DATA[$service_key,url_param_default]}"

  local effective_service_url_param="$service_url_param_default"
  if [[ -n "$service_url_param_override" && "$service_url_param_override" != "null" ]]; then
    effective_service_url_param="$service_url_param_override"
  fi

  # Get latest GitHub release version (uses in-memory Zsh cache first, then file cache via function)
  local latest_gh_version
  if GITHUB_LATEST_VERSION_CACHE[$service_repo]; then
    latest_gh_version="${GITHUB_LATEST_VERSION_CACHE[$service_repo]}"
    # log_info "Cache hit for $service_repo: $latest_gh_version (In-Memory)" # Optional: for debugging
  else
    latest_gh_version=$(get_latest_github_release "$service_repo")
    GITHUB_LATEST_VERSION_CACHE[$service_repo]="$latest_gh_version"
  fi

  # Get deployed version
  local deployed_version=$(get_deployed_version "$effective_service_url_param" "$region_url_param" "$tenant" "$environment" "$DEFAULT_VERSION_JQ_QUERY")

  # Normalize versions (remove leading 'v' if present)
  local normalized_deployed_version="${deployed_version#v}"
  local normalized_latest_gh_version="${latest_gh_version#v}"

  # Determine status
  local status_text
  local raw_status_text # For sorting

  # Handle GitHub fetch errors first
  if [[ "$latest_gh_version" == ERR_GH* || "$latest_gh_version" == "N/A_GH_FETCH" ]]; then
    status_text="${RED}${latest_gh_version}${NC}"
    raw_status_text="GH_ERROR"
  # Handle cases where no releases are found on GitHub
  elif [[ "$latest_gh_version" == "NO_RELEASES" ]]; then
    status_text="${BLUE}NO_GH_RELEASES${NC}"
    raw_status_text="NO_GH_RELEASES"
  # Handle service fetch errors
  elif [[ "$deployed_version" == TIMEOUT_SVC* || "$deployed_version" == ERR_SVC* || "$deployed_version" == HTTP_* || "$deployed_version" == N/A* ]]; then
    status_text="${RED}${deployed_version}${NC}"
    raw_status_text="SVC_ERROR"
  # Compare versions
  elif [[ "$normalized_deployed_version" == "$normalized_latest_gh_version" ]]; then
    status_text="${GREEN}UP-TO-DATE${NC}"
    raw_status_text="UP-TO-DATE"
  else
    status_text="${YELLOW}OUTDATED${NC}"
    raw_status_text="OUTDATED"
  fi

  echo "$target_name|$deployed_version|$latest_gh_version|$status_text|$service_display_name|$tenant|$environment|$region_url_param|$raw_status_text" > "$target_result_file"
}

# --- Main Script Logic ---
main() {
  check_deps

  if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "Config file '$CONFIG_FILE' not found."
    exit 1
  fi

  parse_global_config
  parse_services_repo_map

  log_info "Fetching target data..."
  local targets_json
  targets_json=$(yq e -o=json '.targets' "$CONFIG_FILE")
  if [[ -z "$targets_json" || "$targets_json" == "null" ]]; then
      log_error "No targets found in $CONFIG_FILE or error parsing targets."
      exit 1
  fi

  local num_targets
  num_targets=$(echo "$targets_json" | jq 'length')
  if ! [[ "$num_targets" =~ ^[0-9]+$ ]] || [[ "$num_targets" -eq 0 ]]; then
      log_error "No targets to process."
      exit 1
  fi

  log_info "Processing $num_targets targets with up to $MAX_PARALLEL_JOBS parallel jobs..."

  local pids=()
  local current_jobs=0
  for i in $(seq 0 $((num_targets - 1))); do
    local target_item_json
    target_item_json=$(echo "$targets_json" | jq -c ".[$i]")
    
    process_target "$i" "$target_item_json" &
    pids+=($!)
    ((current_jobs++))

    # Progress indicator - simple dots
    if (( i % 10 == 0 )); then printf "."; fi


    if (( current_jobs >= MAX_PARALLEL_JOBS )); then
      # Wait for the oldest job to finish to free up a slot
      # `wait -n` is ideal, but can be tricky in loops if not handled carefully.
      # Waiting for a specific PID from the list is more robust if we manage the list.
      wait "${pids[1]}" # Wait for the first PID in the current list of background jobs
      # Remove the waited PID from the list.
      # This isn't perfect array manipulation in Zsh for pids, a more robust job control might use a queue.
      # For this purpose, it usually works.
      # A simpler approach if this fails: just `wait -n` if available and works.
      # Or `local temp_pids=(); for pid_ in "${pids[@]}"; do if jobs -p | grep -q "^${pid_}$"; then temp_pids+=($pid_); fi; done; pids=(${temp_pids[@]})`
      # For now, let's assume simple wait for the first one is okay or use wait -n
      if command -v wait &>/dev/null && wait -n; then
        : # A job finished
      else
        # Fallback if wait -n is not available or misbehaves
        wait "${pids[1]}" # Wait for the oldest job in the current batch
        # Correctly remove the waited PID - find its index
        local j
        for ((j=1; j<=${#pids[@]}; ++j)); do
            if [[ ${pids[j]} -eq ${pids[1]} ]]; then # This is not quite right, should be $! from last wait
                # This part needs careful PID management.
                # Simpler: after wait, rebuild pids list from `jobs -p`
                break
            fi
        done
        # If using wait PIDs[1], then remove PIDs[1]
        # pids=("${(@)pids[2,-1]}") # Zsh specific array slicing (if indices are 1-based after wait)
        # Given the simple nature for now, let's just decrement. A more complex job manager would be better.
      fi
       ((current_jobs--))
       # Rebuild pids list to only contain running jobs
       local running_pids=()
       for pid_to_check in "${pids[@]}"; do
         if ps -p "$pid_to_check" > /dev/null; then
           running_pids+=("$pid_to_check")
         fi
       done
       pids=("${running_pids[@]}")
       current_jobs=${#pids[@]} # Recalculate current jobs accurately
    fi
     printf "\rTargets processed: %s/%s. Active jobs: %s " "$((i+1))" "$num_targets" "$current_jobs"
  done
  
  printf "\n" # Newline after progress
  log_info "All targets dispatched. Waiting for remaining jobs to complete..."
  wait # Wait for all remaining background jobs
  
  log_info "All jobs completed. Generating report..."

  local results_array=()
  for i in $(seq 0 $((num_targets - 1))); do
    if [[ -f "$TMP_DIR/result_${i}.txt" ]]; then
      results_array+=("$(cat "$TMP_DIR/result_${i}.txt")")
    else
      # This might happen if a job was killed or had a severe error before writing file
      # log_error "Result file for target index $i not found."
      # For robustness, check if target_item_json can be retrieved and log its name
      local target_item_json_for_error=$(echo "$targets_json" | jq -c ".[$i]")
      local target_name_for_error=$(echo "$target_item_json_for_error" | jq -r '.name // "Unknown Target"')
      log_error "Result file for target '$target_name_for_error' (index $i) not found. Job may have failed."
    fi
  done

  # Determine max column widths
  local max_name_len=12 max_deployed_len=10 max_latest_len=8 max_service_len=15 max_tenant_len=7 max_env_len=5 max_region_len=8
  
  max_name_len=$(( $(echo "Target Name" | wc -m) > max_name_len ? $(echo "Target Name" | wc -m) : max_name_len ))
  max_deployed_len=$(( $(echo "Deployed" | wc -m) > max_deployed_len ? $(echo "Deployed" | wc -m) : max_deployed_len ))
  max_latest_len=$(( $(echo "Latest GH" | wc -m) > max_latest_len ? $(echo "Latest GH" | wc -m) : max_latest_len ))
  max_service_len=$(( $(echo "Service" | wc -m) > max_service_len ? $(echo "Service" | wc -m) : max_service_len ))
  max_tenant_len=$(( $(echo "Tenant" | wc -m) > max_tenant_len ? $(echo "Tenant" | wc -m) : max_tenant_len ))
  max_env_len=$(( $(echo "Env" | wc -m) > max_env_len ? $(echo "Env" | wc -m) : max_env_len ))
  max_region_len=$(( $(echo "Region" | wc -m) > max_region_len ? $(echo "Region" | wc -m) : max_region_len ))

  for line in "${results_array[@]}"; do
    local name deployed latest _ service tenant env region _
    IFS='|' read -r name deployed latest _ service tenant env region _ <<< "$line"
    
    (( ${#name} > max_name_len )) && max_name_len=${#name}
    (( ${#deployed} > max_deployed_len )) && max_deployed_len=${#deployed}
    (( ${#latest} > max_latest_len )) && max_latest_len=${#latest}
    (( ${#service} > max_service_len )) && max_service_len=${#service}
    (( ${#tenant} > max_tenant_len )) && max_tenant_len=${#tenant}
    (( ${#env} > max_env_len )) && max_env_len=${#env}
    (( ${#region} > max_region_len )) && max_region_len=${#region}
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
    "$max_service_len" "Service" \
    "$max_tenant_len" "Tenant" \
    "$max_env_len" "Env" \
    "$max_region_len" "Region" \
    "$max_name_len" "Target Instance" \
    "$max_deployed_len" "Deployed" \
    "$max_latest_len" "Latest GH" \
    "Status"

  local total_width=$((max_service_len + max_tenant_len + max_env_len + max_region_len + max_name_len + max_deployed_len + max_latest_len + 7*3 + 15)) # Adjusted for status width
  printf "%${total_width}s\n" "" | tr " " "-"

  # Sort results: by Service Name, then Raw Status (Errors, Outdated, No Releases, Up-to-date), then Tenant, then Env
  # Define a custom sort order for raw_status_text
  # GH_ERROR, SVC_ERROR, OUTDATED, NO_GH_RELEASES, UP-TO-DATE
  local sorted_results=()
  while IFS= read -r line; do
      sorted_results+=("$line")
  done < <(
      awk -F'|' '
      function status_sort_key(status) {
          if (status == "GH_ERROR") return 1;
          if (status == "SVC_ERROR") return 2;
          if (status == "OUTDATED") return 3;
          if (status == "NO_GH_RELEASES") return 4;
          if (status == "UP-TO-DATE") return 5;
          return 6; # other/unknown
      }
      { print status_sort_key($9) "|" $0 }' <(printf "%s\n" "${results_array[@]}") | \
      sort -t'|' -k1,1n -k6,6 -k7,7 -k8,8 | \
      cut -d'|' -f2-
  )

  for line in "${sorted_results[@]}"; do
    local target_name_val deployed_val latest_val status_val service_val tenant_val env_val region_val raw_status_val
    IFS='|' read -r target_name_val deployed_val latest_val status_val service_val tenant_val env_val region_val raw_status_val <<< "$line"
    printf "$format_string" \
      "$max_service_len" "$service_val" \
      "$max_tenant_len" "$tenant_val" \
      "$max_env_len" "$env_val" \
      "$max_region_len" "$region_val" \
      "$max_name_len" "$target_name_val" \
      "$max_deployed_len" "$deployed_val" \
      "$max_latest_len" "$latest_val" \
      "$status_val"
  done

  log_info "Cleaning up temporary directory: $TMP_DIR"
  rm -rf "$TMP_DIR"
}

# --- Trap for cleanup on exit ---
cleanup_pids=() # Store PIDs for cleanup
cleanup() {
  log_info "Script interrupted or finished. Cleaning up..."
  if [[ -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
  # Kill any remaining direct child background jobs if they were stored in cleanup_pids
  if ((${#cleanup_pids[@]} > 0)); then
    # log_info "Attempting to kill remaining child PIDs: ${cleanup_pids[*]}"
    kill "${cleanup_pids[@]}" 2>/dev/null
  fi
}
trap cleanup EXIT SIGINT SIGTERM

# --- Run ---
main "$@"
