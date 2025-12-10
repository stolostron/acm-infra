#!/usr/bin/env bash

exec 3>&1

# Debug output function
debug_echo() {
  if [ "$debug" = true ]; then
    echo "$@" >&3
  fi
}

show_help() {
    cat << EOF
Usage: compliance.sh [OPTIONS] <application>

Check compliance status for Konflux components

ARGUMENTS:
    <application>    The application name to check (e.g., acm-215)

OPTIONS:
    --debug=<component>   Run against a specific Konflux component only
    --debug               Enable debug logging output
    --retrigger           Retrigger failed components automatically
    --squad=<squad>       Run against components owned by a specific squad
    -h, --help            Show this help message

EXAMPLES:
    compliance.sh acm-215
    compliance.sh --debug=my-component acm-215
    compliance.sh --debug acm-215
    compliance.sh --retrigger acm-215
    compliance.sh --squad=policy acm-215
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --debug=*)
            debug="${1#*=}"
            shift
            ;;
        --debug)
            debug=true
            shift
            ;;
        --retrigger)
            retrigger=true
            shift
            ;;
        --squad=*)
            squad="${1#*=}"
            shift
            ;;
        -h|--help)
            show_help=true
            shift
            ;;
        -*)
            echo "Unknown option $1"
            exit 1
            ;;
        *)
            if [[ -z "$application" ]]; then
                application=$1
            else
                echo "Multiple applications specified: $application and $1"
                exit 1
            fi
            shift
            ;;
    esac
done

# Check for help flag or no arguments
if [[ "$show_help" == "true" ]] || [[ -z "$application" ]]; then
    show_help
    exit 0
fi

# Check that we're in the correct OpenShift project
echo "Checking OpenShift project..."
oc_project_output=$(oc project 2>&1)
if [[ ! "$oc_project_output" == *"Using project \"crt-redhat-acm-tenant\""* ]]; then
    echo "Error: Not in the correct OpenShift project."
    echo "Expected: Using project \"crt-redhat-acm-tenant\""
    echo "Got: $oc_project_output"
    exit 1
fi
echo "Verified: In correct OpenShift project (crt-redhat-acm-tenant)"

mkdir -p data
compliancefile="data/$application-compliance.csv"
> $compliancefile

# Capture scan time (when this script runs)
SCAN_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Image staleness threshold (2 weeks in seconds)
IMAGE_STALE_THRESHOLD=$((14 * 24 * 60 * 60))

# Write CSV header
echo "Konflux Component,Scan Time,Promoted Time,Promoted Status,Hermetic Builds,Enterprise Contract,Multiarch Support,Push Status,Push PipelineRun URL,EC PipelineRun URL" > $compliancefile

# Function to check if image is stale (>2 weeks old) - log only, no CSV output
check_image_stale() {
    local build_time="$1"
    local repo="$2"

    # Check if build_time is a valid timestamp
    if [[ "$build_time" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} ]]; then
        # Remove Z suffix if present
        local build_time_clean="${build_time%Z}"

        # Convert build_time to epoch seconds (macOS compatible)
        local build_epoch
        if [[ "$(uname)" == "Darwin" ]]; then
            build_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$build_time_clean" "+%s" 2>/dev/null)
        else
            build_epoch=$(date -d "$build_time_clean" "+%s" 2>/dev/null)
        fi

        if [[ -n "$build_epoch" ]]; then
            local current_epoch=$(date +%s)
            local age_seconds=$((current_epoch - build_epoch))
            local age_days=$((age_seconds / 86400))

            if [[ $age_seconds -gt $IMAGE_STALE_THRESHOLD ]]; then
                echo "🟥 $repo image stale: TRUE (${age_days} days old)" >&3
                return 1  # stale
            else
                echo "🟩 $repo image stale: FALSE (${age_days} days old)" >&3
                return 0  # fresh
            fi
        fi
    fi

    # If we can't determine the age, show warning
    echo "🟡 $repo image stale: UNKNOWN (invalid timestamp: $build_time)" >&3
    return 0
}

# Function to get components for a specific squad from YAML config
get_squad_components() {
    local squad_key="$1"
    # Get the directory where this script is located
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # Use component-registry.yaml from acm-config submodule
    local config_file="$script_dir/../../../acm-config/product/component-registry.yaml"

    if [[ ! -f "$config_file" ]]; then
        echo "Error: Component registry not found" >&3
        echo "Expected: $config_file" >&3
        echo "" >&3
        echo "Please ensure the acm-config submodule is properly initialized:" >&3
        echo "  git submodule update --init --recursive" >&3
        echo "INVALID_SQUAD"
        exit 1
    fi

    debug_echo "[debug] Squad Key: $squad_key"
    debug_echo "[debug] Config File: $config_file"

    # Convert squad_key from kebab-case to Title Case for matching
    # e.g., "server-foundation" -> "Server Foundation"
    local squad_name=$(echo "$squad_key" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2));}1')
    debug_echo "[debug] Squad Name (normalized): $squad_name"

    # Query components by squad field
    local components=$(yq ".components[] | select(.squad == \"$squad_name\") | .konflux_component" "$config_file" 2>/dev/null)

    # If no exact match, show available squads
    if [[ -z "$components" ]]; then
        debug_echo "[debug] No components found for squad: $squad_name"
        # Get all unique squad values for error message
        local available_squads=$(yq '.components[].squad' "$config_file" 2>/dev/null | sort -u | grep -v '^null$')

        echo "Error: No components found for squad '$squad_key' (normalized: '$squad_name')" >&3
        echo "" >&3
        echo "Available squads:" >&3
        echo "$available_squads" | while read -r squad; do
            echo "  - $squad" >&3
        done
        echo "" >&3
        echo "Hint: Use kebab-case format (e.g., 'server-foundation' for 'Server Foundation')" >&3
        echo "INVALID_SQUAD"
        exit 1
    fi

    debug_echo "[debug] Components found: $(echo "$components" | wc -l | tr -d ' ')"
    echo "$components"
}

# Function to get repository URL from component registry
get_component_repository() {
    local component_name="$1"
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local config_file="$script_dir/../../../acm-config/product/component-registry.yaml"

    # Return empty if config file doesn't exist
    if [[ ! -f "$config_file" ]]; then
        echo ""
        return
    fi

    # Query repository by konflux_component field
    local repository=$(yq ".components[] | select(.konflux_component == \"$component_name\") | .repository" "$config_file" 2>/dev/null)

    # Filter out empty/null values
    if [[ -n "$repository" && "$repository" != "null" ]]; then
        echo "$repository"
    else
        echo ""
    fi
}

echo "Checking for Github auth token"
authorization=""
if [ -f "authorization.txt" ]; then
	authorization="Authorization: Bearer $(cat "authorization.txt")"
	echo "Authorization found. Applying to github API requests"

	# Check current GitHub API rate limit status
	echo ""
	echo "Checking GitHub API rate limit status..."
	rate_limit_response=$(curl -s -H "$authorization" "https://api.github.com/rate_limit")

	if [ $? -eq 0 ]; then
		core_limit=$(echo "$rate_limit_response" | yq -p=json '.rate.limit')
		core_remaining=$(echo "$rate_limit_response" | yq -p=json '.rate.remaining')
		core_used=$(echo "$rate_limit_response" | yq -p=json '.rate.used')
		reset_timestamp=$(echo "$rate_limit_response" | yq -p=json '.rate.reset')

		# Calculate reset time
		current_time=$(date +%s)
		time_until_reset=$((reset_timestamp - current_time))
		minutes_until_reset=$((time_until_reset / 60))

		echo "GitHub API Rate Limit Status:"
		echo "  Limit:     $core_limit requests/hour"
		echo "  Used:      $core_used"
		echo "  Remaining: $core_remaining"
		echo "  Resets in: ${minutes_until_reset} minutes (at $(date -r $reset_timestamp '+%Y-%m-%d %H:%M:%S'))"

		# Warn if low on quota
		usage_percent=$((core_used * 100 / core_limit))
		if [ $core_remaining -lt 500 ]; then
			echo "  ⚠️  WARNING: Less than 500 requests remaining!"
		elif [ $usage_percent -gt 80 ]; then
			echo "  ⚠️  WARNING: Over 80% quota used (${usage_percent}%)"
		else
			echo "  ✓ Sufficient quota available (${usage_percent}% used)"
		fi
	else
		echo "⚠️  Could not fetch rate limit status"
	fi
	echo ""
fi

# GitHub API call with simple rate limiting and retry logic
github_api_call() {
    local url="$1"
    local max_retries=3
    local retry_delay=2
    local attempt=1

    while [ $attempt -le $max_retries ]; do
        # Make the API call
        response=$(curl -LsH "$authorization" -w "\n%{http_code}" "$url" 2>&1)
        http_code=$(echo "$response" | tail -n 1)
        body=$(echo "$response" | sed '$d')

        debug_echo "[debug] API call to $url returned HTTP $http_code"

        # Check for rate limit (403/429)
        # Only treat as rate limit if we have an error response (not valid data)
        if [[ "$http_code" == "403" ]] || [[ "$http_code" == "429" ]]; then
            # Check if response has valid data (check_suites or check_runs array exists)
            has_valid_data=$(echo "$body" | yq -p=json 'has("check_suites") or has("check_runs")' 2>/dev/null)
            if [[ "$has_valid_data" == "true" ]]; then
                # Response contains valid data despite 403 - not a rate limit error
                debug_echo "[debug] Got 403 but response has valid data, treating as success"
                echo "$body"
                return 0
            fi
            if echo "$body" | grep -qi "rate limit\|API rate limit"; then
                # Fetch detailed rate limit information
                echo "⚠️  GitHub API rate limit hit" >&3
                echo "   Request URL: $url" >&3
                echo "   HTTP Code: $http_code" >&3
                echo "" >&3

                if [[ -n "$authorization" ]]; then
                    rate_limit_response=$(curl -s -H "$authorization" "https://api.github.com/rate_limit" 2>&1)

                    if [ $? -eq 0 ]; then
                        # Try to parse rate limit details
                        core_limit=$(echo "$rate_limit_response" | yq -p=json '.rate.limit' 2>/dev/null)
                        core_remaining=$(echo "$rate_limit_response" | yq -p=json '.rate.remaining' 2>/dev/null)
                        core_used=$(echo "$rate_limit_response" | yq -p=json '.rate.used' 2>/dev/null)
                        reset_timestamp=$(echo "$rate_limit_response" | yq -p=json '.rate.reset' 2>/dev/null)

                        # Filter out "null" values
                        [[ "$core_limit" == "null" ]] && core_limit=""
                        [[ "$core_remaining" == "null" ]] && core_remaining=""
                        [[ "$core_used" == "null" ]] && core_used=""
                        [[ "$reset_timestamp" == "null" ]] && reset_timestamp=""

                        if [[ -n "$core_limit" && -n "$core_remaining" && -n "$core_used" ]]; then
                            current_time=$(date +%s)
                            time_until_reset=$((reset_timestamp - current_time))
                            minutes_until_reset=$((time_until_reset / 60))
                            usage_percent=$((core_used * 100 / core_limit))

                            echo "   📊 GitHub API Rate Limit Details:" >&3
                            echo "      Limit:     $core_limit requests/hour" >&3
                            echo "      Used:      $core_used (${usage_percent}%)" >&3
                            echo "      Remaining: $core_remaining" >&3
                            echo "      Resets in: ${minutes_until_reset} minutes (at $(date -r $reset_timestamp '+%Y-%m-%d %H:%M:%S'))" >&3
                            echo "" >&3

                            # If rate limit is truly exhausted (very few remaining), don't retry
                            if [[ $core_remaining -lt 10 ]]; then
                                echo "❌ Rate limit exhausted (only $core_remaining requests remaining)" >&3
                                echo "   Retrying won't help - need to wait for rate limit reset" >&3
                                echo "   Please run the script again after $(date -r $reset_timestamp '+%Y-%m-%d %H:%M:%S')" >&3
                                return 1
                            fi
                        else
                            # Failed to parse rate limit details - show raw response for debugging
                            echo "   ⚠️  Failed to parse rate limit details" >&3
                            echo "   Raw response from GitHub API:" >&3
                            echo "$rate_limit_response" | head -20 >&3
                            echo "" >&3
                        fi
                    else
                        echo "   ⚠️  Failed to fetch rate limit information from GitHub API" >&3
                        echo "" >&3
                    fi
                else
                    echo "   ⚠️  No GitHub authorization token configured" >&3
                    echo "   Cannot fetch detailed rate limit information" >&3
                    echo "" >&3
                fi

                if [ $attempt -lt $max_retries ]; then
                    echo "   Retrying in ${retry_delay}s (attempt $attempt/$max_retries)..." >&3
                    sleep $retry_delay
                    retry_delay=$((retry_delay * 2))
                    attempt=$((attempt + 1))
                    continue
                else
                    echo "❌ Rate limit exceeded after $max_retries retries" >&3
                    return 1
                fi
            fi
        elif [[ "$http_code" =~ ^5[0-9]{2}$ ]]; then
            # Server error, retry
            if [ $attempt -lt $max_retries ]; then
                echo "⚠️  GitHub API server error ($http_code), retrying in ${retry_delay}s..." >&3
                sleep $retry_delay
                retry_delay=$((retry_delay * 2))
                attempt=$((attempt + 1))
                continue
            fi
        fi

        # Success
        echo "$body"
        return 0
    done

    return 1
}

# Detect macOS ARM64 for skopeo platform override
detected_os=$(uname -s)
detected_arch=$(uname -m)
if [[ "$detected_os" == "Darwin" && "$detected_arch" == "arm64" ]]; then
    echo "Detected macOS ARM64. Adding skopeo platform override."
    skopeo_mac_args="--override-arch amd64 --override-os linux"
fi

# Function to check promoted image and get build time
check_promoted() {
    local line="$1"
    local skopeo_mac_args="$2"
    
    promoted=$(oc get component $line -oyaml | yq ".status.lastPromotedImage")
    if [[ "$promoted" == "null" || -z "$promoted" ]]; then
        # failed to get image
        # echo "failed to get image"
        buildtime="IMAGE_PULL_FAILURE,Failed"
    elif [[ "$promoted" =~ sha256:[a-f0-9]{64}$ ]]; then
        # found image
        skopeo=$(skopeo $skopeo_mac_args inspect "docker://$promoted" 2>/dev/null)
        if [ $? -ne 0 ]; then
            # inspection failed
            buildtime="INSPECTION_FAILURE,Failed"
        else
            buildtime="$(echo "$skopeo" | yq -p=json ".Labels.build-date" | sed 's/Z$//'),Successful"
        fi
    else
        # invalid or incomplete digest
        buildtime="DIGEST_FAILURE,Failed"
    fi
    
    echo "$buildtime"
}

# Function to check hermetic builds
check_hermetic_builds() {
    local yaml="$1"
    local pull_yaml="$2"
    local authorization="$3"
    local org="$4"
    local repo="$5"
    
    hermeticbuilds=true
    
    # Check pathInRepo (first .spec, then fallback to .spec.pipelineSpec)
    pathinrepo=$(echo "$yaml" | yq ".spec.pipelineRef.params | .[] | select(.name==\"pathInRepo\")" 2>&1)
    if echo "$pathinrepo" | grep -q "Error:"; then
        echo "⚠️  Error parsing push YAML for pathInRepo (.spec):" >&3
        echo "$pathinrepo" >&3
        echo "Push YAML content (first 300 lines):" >&3
        echo "$yaml" | head -300 >&3
        pathinrepo=""
    fi
    debug_echo "[debug] pathInRepo (push): using .spec = $pathinrepo"
    if [[ -z "$pathinrepo" ]]; then
        pathinrepo=$(echo "$yaml" | yq ".spec.pipelineSpec.pipelineRef.params | .[] | select(.name==\"pathInRepo\")" 2>&1)
        if echo "$pathinrepo" | grep -q "Error:"; then
            echo "⚠️  Error parsing push YAML for pathInRepo (.spec.pipelineSpec fallback):" >&3
            echo "$pathinrepo" >&3
            pathinrepo=""
        fi
        debug_echo "[debug] pathInRepo (push): using .spec.pipelineSpec fallback = $pathinrepo"
    fi

    pullpathinrepo=$(echo "$pull_yaml" | yq ".spec.pipelineRef.params | .[] | select(.name==\"pathInRepo\")" 2>&1)
    if echo "$pullpathinrepo" | grep -q "Error:"; then
        echo "⚠️  Error parsing pull YAML for pathInRepo (.spec):" >&3
        echo "$pullpathinrepo" >&3
        echo "Pull YAML content (first 300 lines):" >&3
        echo "$pull_yaml" | head -300 >&3
        pullpathinrepo=""
    fi
    debug_echo "[debug] pathInRepo (pull): using .spec = $pullpathinrepo"
    if [[ -z "$pullpathinrepo" ]]; then
        pullpathinrepo=$(echo "$pull_yaml" | yq ".spec.pipelineSpec.pipelineRef.params | .[] | select(.name==\"pathInRepo\")" 2>&1)
        if echo "$pullpathinrepo" | grep -q "Error:"; then
            echo "⚠️  Error parsing pull YAML for pathInRepo (.spec.pipelineSpec fallback):" >&3
            echo "$pullpathinrepo" >&3
            pullpathinrepo=""
        fi
        debug_echo "[debug] pathInRepo (pull): using .spec.pipelineSpec fallback = $pullpathinrepo"
    fi

    if [[ -z "$pathinrepo" || -z "$pullpathinrepo" ]]; then
        # Check build-source-image (first .spec.params.value, then fallback to .spec.pipelineSpec.params.default)
        buildsourceimage=$(echo "$yaml" | yq ".spec.params | .[] | select(.name==\"build-source-image\") | .value" 2>&1)
        if echo "$buildsourceimage" | grep -q "Error:"; then
            echo "⚠️  Error parsing push YAML for build-source-image:" >&3
            echo "$buildsourceimage" >&3
            buildsourceimage=""
        fi
        debug_echo "[debug] build-source-image (push): using .spec.params.value = $buildsourceimage"
        if [[ -z "$buildsourceimage" ]]; then
            buildsourceimage=$(echo "$yaml" | yq ".spec.pipelineSpec.params | .[] | select(.name==\"build-source-image\") | .default" 2>&1)
            if echo "$buildsourceimage" | grep -q "Error:"; then
                echo "⚠️  Error parsing push YAML for build-source-image (fallback):" >&3
                echo "$buildsourceimage" >&3
                buildsourceimage=""
            fi
            debug_echo "[debug] build-source-image (push): using .spec.pipelineSpec.params.default = $buildsourceimage"
        fi

        pull_bsi=$(echo "$pull_yaml" | yq ".spec.params | .[] | select(.name==\"build-source-image\") | .value" 2>&1)
        if echo "$pull_bsi" | grep -q "Error:"; then
            echo "⚠️  Error parsing pull YAML for build-source-image:" >&3
            echo "$pull_bsi" >&3
            pull_bsi=""
        fi
        debug_echo "[debug] build-source-image (pull): using .spec.params.value = $pull_bsi"
        if [[ -z "$pull_bsi" ]]; then
            pull_bsi=$(echo "$pull_yaml" | yq ".spec.pipelineSpec.params | .[] | select(.name==\"build-source-image\") | .default" 2>&1)
            if echo "$pull_bsi" | grep -q "Error:"; then
                echo "⚠️  Error parsing pull YAML for build-source-image (fallback):" >&3
                echo "$pull_bsi" >&3
                pull_bsi=""
            fi
            debug_echo "[debug] build-source-image (pull): using .spec.pipelineSpec.params.default = $pull_bsi"
        fi
        
        if [[ !($buildsourceimage == true || $buildsourceimage == "true") || !($pull_bsi == true || $pull_bse == "true") ]]; then
            hermeticbuilds=false
        fi

        # Check hermetic (first .spec.params.value, then fallback to .spec.pipelineSpec.params.default)
        hermetic=$(echo "$yaml" | yq ".spec.params | .[] | select(.name==\"hermetic\") | .value" 2>&1)
        if echo "$hermetic" | grep -q "Error:"; then
            echo "⚠️  Error parsing push YAML for hermetic:" >&3
            echo "$hermetic" >&3
            hermetic=""
        fi
        debug_echo "[debug] hermetic (push): using .spec.params.value = $hermetic"
        if [[ -z "$hermetic" ]]; then
            hermetic=$(echo "$yaml" | yq ".spec.pipelineSpec.params | .[] | select(.name==\"hermetic\") | .default" 2>&1)
            if echo "$hermetic" | grep -q "Error:"; then
                echo "⚠️  Error parsing push YAML for hermetic (fallback):" >&3
                echo "$hermetic" >&3
                hermetic=""
            fi
            debug_echo "[debug] hermetic (push): using .spec.pipelineSpec.params.default = $hermetic"
        fi

        pull_hermetic=$(echo "$pull_yaml" | yq ".spec.params | .[] | select(.name==\"hermetic\") | .value" 2>&1)
        if echo "$pull_hermetic" | grep -q "Error:"; then
            echo "⚠️  Error parsing pull YAML for hermetic:" >&3
            echo "$pull_hermetic" >&3
            pull_hermetic=""
        fi
        debug_echo "[debug] hermetic (pull): using .spec.params.value = $pull_hermetic"
        if [[ -z "$pull_hermetic" ]]; then
            pull_hermetic=$(echo "$pull_yaml" | yq ".spec.pipelineSpec.params | .[] | select(.name==\"hermetic\") | .default" 2>&1)
            if echo "$pull_hermetic" | grep -q "Error:"; then
                echo "⚠️  Error parsing pull YAML for hermetic (fallback):" >&3
                echo "$pull_hermetic" >&3
                pull_hermetic=""
            fi
            debug_echo "[debug] hermetic (pull): using .spec.pipelineSpec.params.default = $pull_hermetic"
        fi
        
        if [[ $hermetic != true || $hermetic != "true" || $pull_hermetic != true || $pull_hermetic != "true" ]]; then
            hermeticbuilds=false
        fi
    fi

    vendor_response=$(github_api_call "https://api.github.com/repos/$org/$repo/contents/vendor")
    if [ $? -eq 0 ] && [ -n "$vendor_response" ]; then
        vendor="200"
    else
        vendor="404"
    fi
    
    # Check prefetch-input (first .spec.params.value, then fallback to .spec.pipelineSpec.params.default)
    prefetch=$(echo "$yaml" | yq ".spec.params | .[] | select(.name==\"prefetch-input\") | .value" 2>&1)
    if echo "$prefetch" | grep -q "Error:"; then
        echo "⚠️  Error parsing push YAML for prefetch-input:" >&3
        echo "$prefetch" >&3
        prefetch=""
    fi
    debug_echo "[debug] prefetch-input (push): using .spec.params.value = $prefetch"
    if [[ -z "$prefetch" ]]; then
        prefetch=$(echo "$yaml" | yq ".spec.pipelineSpec.params | .[] | select(.name==\"prefetch-input\") | .default" 2>&1)
        if echo "$prefetch" | grep -q "Error:"; then
            echo "⚠️  Error parsing push YAML for prefetch-input (fallback):" >&3
            echo "$prefetch" >&3
            prefetch=""
        fi
        debug_echo "[debug] prefetch-input (push): using .spec.pipelineSpec.params.default = $prefetch"
    fi

    pull_prefetch=$(echo "$pull_yaml" | yq ".spec.params | .[] | select(.name==\"prefetch-input\") | .value" 2>&1)
    if echo "$pull_prefetch" | grep -q "Error:"; then
        echo "⚠️  Error parsing pull YAML for prefetch-input:" >&3
        echo "$pull_prefetch" >&3
        pull_prefetch=""
    fi
    debug_echo "[debug] prefetch-input (pull): using .spec.params.value = $pull_prefetch"
    if [[ -z "$pull_prefetch" ]]; then
        pull_prefetch=$(echo "$pull_yaml" | yq ".spec.pipelineSpec.params | .[] | select(.name==\"prefetch-input\") | .default" 2>&1)
        if echo "$pull_prefetch" | grep -q "Error:"; then
            echo "⚠️  Error parsing pull YAML for prefetch-input (fallback):" >&3
            echo "$pull_prefetch" >&3
            pull_prefetch=""
        fi
        debug_echo "[debug] prefetch-input (pull): using .spec.pipelineSpec.params.default = $pull_prefetch"
    fi
    
    # echo "$prefetch $pull_prefetch"
    # echo -e "Prefetch: $prefetch\nPullPrefetch: $pull_prefetch\nVendor: $vendor"
    if [[ ($prefetch == "" || $pull_prefetch == "") && $vendor != "200" ]]; then
        # echo "prefetch failure"
        hermeticbuilds=false
    fi

    if [[ $hermeticbuilds == true ]]; then
        echo "🟩 $repo hermetic builds: TRUE" >&3
        echo "Enabled"
    else
        echo "🟥 $repo hermetic builds: FALSE" >&3
        echo "Not Enabled"
    fi
}

# Function to fetch all check runs for a component (called once per component)
fetch_check_runs() {
    local org="$1"
    local repo="$2"
    local branch="$3"

    # Try check-suites first (more reliable for Konflux)
    check_suites_response=$(github_api_call "https://api.github.com/repos/$org/$repo/commits/$branch/check-suites")
    suite_id=$(echo "$check_suites_response" | yq -p=json ".check_suites[] | select(.app.name == \"Red Hat Konflux\") | .id" 2>&1 | head -1)
    if echo "$suite_id" | grep -q "Error:"; then
        echo "⚠️  Error parsing check-suites response:" >&3
        echo "$suite_id" >&3
        echo "Check-suites JSON response (first 500 lines):" >&3
        echo "$check_suites_response" | head -500 >&3
        suite_id=""
    fi

    if [[ -n "$suite_id" ]]; then
        # Use suite method for Konflux - fetch ALL check runs at once
        all_check_runs=$(github_api_call "https://api.github.com/repos/$org/$repo/check-suites/$suite_id/check-runs")
        debug_echo "[debug] Fetched check runs via suite ID: $suite_id"
        echo "$all_check_runs"
    else
        # Fallback to original method
        all_check_runs=$(github_api_call "https://api.github.com/repos/$org/$repo/commits/$branch/check-runs")
        debug_echo "[debug] Fetched check runs via commit (fallback)"
        echo "$all_check_runs"
    fi
}

# Function to check enterprise contract (using pre-fetched check runs)
check_enterprise_contract() {
    local application="$1"
    local line="$2"
    local repo="$3"
    local all_check_runs="$4"

    ecname="enterprise-contract-$application / $line"

    # Extract EC check run from pre-fetched data
    check_run_data=$(echo "$all_check_runs" | yq -p=json ".check_runs[] | select(.name==\"*enterprise-contract*$line\")" 2>&1)
    if echo "$check_run_data" | grep -q "Error:"; then
        echo "⚠️  Error parsing check runs JSON for EC:" >&3
        echo "$check_run_data" >&3
        echo "Check runs JSON response (first 500 lines):" >&3
        echo "$all_check_runs" | head -500 >&3
        check_run_data=""
    fi
    debug_echo "[debug] EC check_run_data: $check_run_data"
    ec=$(echo "$check_run_data" | yq ".conclusion" 2>&1)
    if echo "$ec" | grep -q "Error:"; then
        echo "⚠️  Error parsing EC conclusion:" >&3
        echo "$ec" >&3
        ec=""
    fi
    # Extract PipelineRun URL from output.text (embedded in HTML link)
    output_text=$(echo "$check_run_data" | yq ".output.text" 2>&1)
    if echo "$output_text" | grep -q "Error:"; then
        echo "⚠️  Error parsing EC output.text:" >&3
        echo "$output_text" >&3
        output_text=""
    fi
    ec_url=$(echo "$output_text" | sed -n 's/.*href="\(https:\/\/konflux-ui[^"]*pipelinerun\/[^"]*\)".*/\1/p' | head -1)
    debug_echo "[debug] EC ec=$ec, ec_url=$ec_url"

    if [[ -n "$ec" ]] && ! echo "$ec" | grep -v "^success$" > /dev/null; then
        echo "🟩 $repo $ecname: SUCCESS" >&3
        echo "Compliant|$ec_url"
    elif [[ "$ec" == "null" ]]; then
        echo "⚠️  $repo $ecname: WARNING (ec conclusion was null - check may not have run yet)" >&3
        echo "EC_NULL|$ec_url"
    else
        echo "🟥 $repo $ecname: FAILURE (ec was: \"$ec\")" >&3
        if [[ -z "$ec" ]]; then
            echo "EC_BLANK|$ec_url"
        elif [[ "$ec" == "cancelled" ]]; then
            echo "EC_CANCELED|$ec_url"
        else
            echo "Not Compliant|$ec_url"
        fi
    fi
}

# Function to check component on-push task run (using pre-fetched check runs)
check_component_on_push() {
    local line="$1"
    local repo="$2"
    local all_check_runs="$3"

    pushname="Red Hat Konflux / $line-on-push"

    # Extract on-push check run from pre-fetched data
    check_run_data=$(echo "$all_check_runs" | yq -p=json ".check_runs[] | select(.name==\"Red Hat Konflux / $line-on-push\")" 2>&1)
    if echo "$check_run_data" | grep -q "Error:"; then
        echo "⚠️  Error parsing check runs JSON for on-push:" >&3
        echo "$check_run_data" >&3
        echo "Check runs JSON response (first 500 lines):" >&3
        echo "$all_check_runs" | head -500 >&3
        check_run_data=""
    fi
    debug_echo "[debug] Push check_run_data: $check_run_data"
    push_status=$(echo "$check_run_data" | yq ".conclusion" 2>&1)
    if echo "$push_status" | grep -q "Error:"; then
        echo "⚠️  Error parsing push status conclusion:" >&3
        echo "$push_status" >&3
        push_status=""
    fi
    push_url=$(echo "$check_run_data" | yq ".details_url" 2>&1)
    if echo "$push_url" | grep -q "Error:"; then
        echo "⚠️  Error parsing push details_url:" >&3
        echo "$push_url" >&3
        push_url=""
    fi
    debug_echo "[debug] Push push_status=$push_status, push_url=$push_url"

    if [[ -n "$push_status" ]] && ! echo "$push_status" | grep -v "^success$" > /dev/null; then
        echo "🟩 $repo $pushname: SUCCESS" >&3
        echo "Successful|$push_url"
    elif [[ "$push_status" == "null" ]]; then
        echo "⚠️  $repo $pushname: WARNING (push status was null - check may not have run yet)" >&3
        echo "PUSH_NULL|$push_url"
    else
        echo "🟥 $repo $pushname: FAILURE (status was: \"$push_status\")" >&3
        echo "Failed|$push_url"
    fi
}

# Function to check multiarch support
check_multiarch_support() {
    local yaml="$1"
    local repo="$2"

    # Check build-platforms (first .spec.params.value, then fallback to .spec.pipelineSpec.params.default)
    platforms_value=$(echo "$yaml" | yq ".spec.params | .[] | select(.name==\"build-platforms\") | .value | .[]" 2>&1)
    if echo "$platforms_value" | grep -q "Error:"; then
        echo "⚠️  Error parsing YAML for build-platforms (.spec.params):" >&3
        echo "$platforms_value" >&3
        echo "YAML content (first 300 lines):" >&3
        echo "$yaml" | head -300 >&3
        platforms_value=""
    fi
    if [[ -z "$platforms_value" ]]; then
        platforms_value=$(echo "$yaml" | yq ".spec.pipelineSpec.params | .[] | select(.name==\"build-platforms\") | .default | .[]" 2>&1)
        if echo "$platforms_value" | grep -q "Error:"; then
            echo "⚠️  Error parsing YAML for build-platforms (.spec.pipelineSpec fallback):" >&3
            echo "$platforms_value" >&3
            platforms_value=""
        fi
    fi

    platforms=$(echo "$platforms_value" | wc -l | tr -d ' \t\n')
    if  [[ $platforms != 4 ]]; then
        echo "🟥 $repo Multiarch: FALSE" >&3
        echo "Not Enabled"
    else
        echo "🟩 $repo Multiarch: TRUE" >&3
        echo "Enabled"
    fi
}

# Function to check if component is a bundle operator
check_bundle_operator() {
    local component="$1"
    
    # Check if component starts with "mce-operator-bundle" or "acm-operator-bundle"
    if [[ "$component" == mce-operator-bundle* || "$component" == acm-operator-bundle* ]]; then
        echo "🟡 $component Bundle Operator: TRUE" >&3
        echo "🟡 $component Hermetic: Not Applicable" >&3
        echo "🟡 $component Multiarch: Not Applicable" >&3
        echo "BUNDLE_OPERATOR"
    else
        echo "REGULAR_COMPONENT"
    fi
}

if [[ -n "$debug" && "$debug" != "true" ]]; then
    components=$debug
elif [[ -n "$squad" ]]; then
    # Get components for the specified squad
    squad_components=$(get_squad_components "$squad")
    if [[ "$squad_components" == "INVALID_SQUAD" ]]; then
        exit 1
    fi
    # Filter by application
    components=$(oc get components | grep $application | awk '{print $1}' | grep -F -f <(echo "$squad_components"))
else
    components=$(oc get components | grep $application | awk '{print $1}')
fi

# Component processing delay (in seconds) to avoid GitHub API rate limits
COMPONENT_DELAY=2

component_count=0
total_components=$(echo "$components" | wc -l | tr -d ' ')

for line in $components; do
    # Skip empty lines
    if [[ -z "$line" ]]; then
        continue
    fi

    component_count=$((component_count + 1))
    echo "Processing component $component_count/$total_components: $line" >&3

    # Add delay between components (except for the first one)
    if [[ $component_count -gt 1 ]]; then
        debug_echo "[debug] Waiting ${COMPONENT_DELAY}s before processing next component..."
        sleep $COMPONENT_DELAY
    fi

    data=$(check_promoted "$line" "$skopeo_mac_args")

    # Extract build time from data (format: "buildtime,status")
    build_time="${data%%,*}"

    url=$(oc get component "$line" -oyaml | yq ".spec.source.git.url")
    branch=$(oc get component "$line" -oyaml | yq ".spec.source.git.revision")
    org=$(basename $(dirname $url))
    repo=$(basename $url)

    push="https://raw.githubusercontent.com/$org/$repo/refs/heads/$branch/.tekton/$line-push.yaml"
    pull="https://raw.githubusercontent.com/$org/$repo/refs/heads/$branch/.tekton/$line-pull-request.yaml"

    debug_echo "[debug] Push: $push\n[debug] Pull: $pull" # debug

    echo "--- $line : $org/$repo : $branch ---"

    # Get repository URL from component registry (if available)
    registry_repo=$(get_component_repository "$line")
    if [[ -n "$registry_repo" ]]; then
        echo "    Repository: $registry_repo"
    fi
    yaml=$(curl -Ls -w "%{http_code}" $push)
    http_code_push="${yaml: -3}"
    yaml="${yaml%???}"
    [[ -n "$debug" && "$http_code_push" == "404" ]] && echo -e "[debug] \033[31m404 error\033[0m fetching push YAML from $push" >&3

    pull_yaml=$(curl -Ls -w "%{http_code}" $pull)
    http_code_pull="${pull_yaml: -3}"
    pull_yaml="${pull_yaml%???}"
    [[ -n "$debug" && "$http_code_pull" == "404" ]] && echo -e "[debug] \033[31m404 error\033[0m fetching pull YAML from $pull" >&3

    # Check if component is a bundle operator
    bundle_result=$(check_bundle_operator "$line")

    # Check if image is stale (>2 weeks old) - log only
    check_image_stale "$build_time" "$repo"

    # Check hermetic builds (skip for bundle operators)
    if [[ "$bundle_result" == "BUNDLE_OPERATOR" ]]; then
        data="$data,Not Applicable"
    else
        data="$data,$(check_hermetic_builds "$yaml" "$pull_yaml" "$authorization" "$org" "$repo")"
    fi

    # Fetch all check runs once for this component (reduces API calls from 4 to 2)
    all_check_runs=$(fetch_check_runs "$org" "$repo" "$branch")

    # Check enterprise contract using pre-fetched data
    ec_result=$(check_enterprise_contract "$application" "$line" "$repo" "$all_check_runs")
    # Extract EC status and URL (format: "Status|URL")
    ec_status="${ec_result%%|*}"
    ec_url="${ec_result##*|}"

    # Check on-push using pre-fetched data
    push_result=$(check_component_on_push "$line" "$repo" "$all_check_runs")
    # Extract push status and URL (format: "Status|URL")
    push_status="${push_result%%|*}"
    push_url="${push_result##*|}"

    # If EC was blank or canceled, check on-push status to determine final EC result
    if [[ "$ec_status" == "EC_BLANK" || "$ec_status" == "EC_CANCELED" ]]; then
        if [[ "$push_status" == "Successful" ]]; then
            ec_status="Not Compliant"
        else
            ec_status="Push Failure"
        fi
    fi

    data="$data,$ec_status"

    # Check multiarch support (skip for bundle operators)
    if [[ "$bundle_result" == "BUNDLE_OPERATOR" ]]; then
        data="$data,Not Applicable"
    else
        data="$data,$(check_multiarch_support "$yaml" "$repo")"
    fi

    # Append Push Status and PipelineRun URLs
    data="$data,$push_status,$push_url,$ec_url"

    echo ""

    echo "$line,$SCAN_TIME,$data" >> $compliancefile

    # Retrigger component if build failed and --retrigger flag is set
    if [[ "$retrigger" == "true" ]]; then
        # Check if component has any failures (Push Failure or actual Failed status, but not Successful)
        if echo "$data" | grep -qE "(^|,)(Failed|Push Failure|IMAGE_PULL_FAILURE|INSPECTION_FAILURE|DIGEST_FAILURE|Not Enabled|Not Compliant)(,|$)"; then
            echo "🔄 Retriggering component: $line" >&3
            kubectl annotate components/$line build.appstudio.openshift.io/request=trigger-pac-build --overwrite
            if [ $? -eq 0 ]; then
                echo "✅ Successfully triggered rebuild for $line" >&3
            else
                echo "❌ Failed to trigger rebuild for $line" >&3
            fi
        fi
    fi
done

echo "" >&3
echo "✅ Compliance scan completed" >&3
