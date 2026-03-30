#!/usr/bin/env bash
# Pending state management for smart denoising
#
# Instead of creating JIRA issues immediately when a failure is detected,
# this module implements a two-scan confirmation pattern:
#   1. Scan 1: Failure detected -> retrigger build -> record in pending state -> NO JIRA
#   2. Scan 2 (after RETRIGGER_WAIT_MINUTES): Re-check pending components
#      - Still failing -> confirmed failure -> create JIRA
#      - Now passing -> remove from pending -> no JIRA
#
# State is stored in a JSON file managed via jq.
# The file is persisted across workflow runs using GitHub Actions cache.

PENDING_FILE="${PENDING_FILE:-pending-failures.json}"

# Minutes to wait after retrigger before re-checking (default: 60)
# This allows the retriggered build enough time to complete.
RETRIGGER_WAIT_MINUTES="${RETRIGGER_WAIT_MINUTES:-60}"

# Number of retrigger attempts required before confirming a failure (default: 2)
# With default value of 2, the flow is:
#   Scan 1: fail → retrigger #1 (count=0)
#   Scan 2: fail → retrigger #2 (count=1)
#   Scan 3: fail → retrigger #3 (count=2)
#   Scan 4: fail → count=2 >= 2 → CONFIRMED → create JIRA
# Set to 3 for even more conservative behavior (4 retriggers before JIRA).
CONFIRMED_FAILURE_THRESHOLD="${CONFIRMED_FAILURE_THRESHOLD:-2}"

# Stale entry cleanup threshold in hours (default: 48)
PENDING_STALE_HOURS="${PENDING_STALE_HOURS:-48}"

# Initialize empty state file if it does not exist or is empty
init_pending_state() {
    if [[ ! -f "$PENDING_FILE" ]] || [[ ! -s "$PENDING_FILE" ]]; then
        echo '{}' > "$PENDING_FILE"
    fi

    # Validate that the file contains valid JSON
    if ! jq empty "$PENDING_FILE" 2>/dev/null; then
        echo "[pending-state] Warning: Invalid JSON in $PENDING_FILE, reinitializing" >&2
        echo '{}' > "$PENDING_FILE"
    fi
}

# Check if component is in pending state
# Args: component_name
# Returns: 0 if pending, 1 if not
is_pending() {
    local component="$1"
    jq -e --arg c "$component" 'has($c)' "$PENDING_FILE" >/dev/null 2>&1
}

# Add component to pending state
# Args: component_name, app_name, failed_dimensions (comma-separated)
# Records: first_seen timestamp, retrigger_time, retrigger_count=0, failed dimensions
add_to_pending() {
    local component="$1"
    local app_name="$2"
    local failed_dimensions="$3"
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local tmp
    tmp=$(mktemp)
    jq --arg c "$component" \
       --arg app "$app_name" \
       --arg dims "$failed_dimensions" \
       --arg ts "$now" \
       '.[$c] = {
           "app": $app,
           "first_seen": $ts,
           "retrigger_time": $ts,
           "retrigger_count": 0,
           "failed_dimensions": $dims
       }' "$PENDING_FILE" > "$tmp" && mv "$tmp" "$PENDING_FILE"
}

# Get how many times component has been retriggered
# Args: component_name
# Outputs: retrigger count (integer)
get_retrigger_count() {
    local component="$1"
    jq -r --arg c "$component" '.[$c].retrigger_count // 0' "$PENDING_FILE"
}

# Increment retrigger count and update retrigger_time for component
# Args: component_name
increment_retrigger() {
    local component="$1"
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local tmp
    tmp=$(mktemp)
    jq --arg c "$component" \
       --arg ts "$now" \
       '.[$c].retrigger_count = ((.[$c].retrigger_count // 0) + 1) | .[$c].retrigger_time = $ts' \
       "$PENDING_FILE" > "$tmp" && mv "$tmp" "$PENDING_FILE"
}

# Remove component from pending state (it passed or was confirmed)
# Args: component_name
remove_from_pending() {
    local component="$1"

    local tmp
    tmp=$(mktemp)
    jq --arg c "$component" 'del(.[$c])' "$PENDING_FILE" > "$tmp" && mv "$tmp" "$PENDING_FILE"
}

# List all components currently in pending state (one per line)
get_pending_components() {
    jq -r 'keys[]' "$PENDING_FILE" 2>/dev/null
}

# Check if enough time has elapsed since retrigger to allow re-checking
# Args: component_name
# Returns: 0 if ready for recheck, 1 if still waiting
is_ready_for_recheck() {
    local component="$1"
    local retrigger_time
    retrigger_time=$(jq -r --arg c "$component" '.[$c].retrigger_time // empty' "$PENDING_FILE")

    if [[ -z "$retrigger_time" ]]; then
        # No retrigger_time recorded, treat as ready
        return 0
    fi

    local wait_minutes="${RETRIGGER_WAIT_MINUTES:-60}"
    local now
    now=$(date +%s)

    # Parse the retrigger_time to epoch seconds (cross-platform)
    local retrigger_time_clean="${retrigger_time%Z}"
    local retrigger_epoch=""

    # Try GNU date first (Linux), then BSD date (macOS)
    # Use -u flag to parse as UTC (timestamps are stored in UTC)
    if retrigger_epoch=$(date -u -d "$retrigger_time_clean" +%s 2>/dev/null); then
        : # success
    elif retrigger_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "$retrigger_time_clean" +%s 2>/dev/null); then
        : # success
    else
        echo "[pending-state] Warning: Could not parse retrigger_time '$retrigger_time', treating as ready" >&2
        return 0
    fi

    local elapsed_minutes=$(( (now - retrigger_epoch) / 60 ))

    if [[ "$elapsed_minutes" -ge "$wait_minutes" ]]; then
        return 0  # Ready for recheck
    else
        return 1  # Still waiting
    fi
}

# Check if component is a confirmed failure (retriggered enough times and ready for recheck)
# Args: component_name
# Returns: 0 if confirmed (retrigger_count >= CONFIRMED_FAILURE_THRESHOLD AND enough time elapsed), 1 if still pending
is_confirmed_failure() {
    local component="$1"
    local retrigger_count
    retrigger_count=$(get_retrigger_count "$component")
    local threshold="${CONFIRMED_FAILURE_THRESHOLD:-2}"

    if [[ "$retrigger_count" -ge "$threshold" ]] && is_ready_for_recheck "$component"; then
        return 0  # Confirmed failure
    fi

    return 1  # Still pending
}

# Remove entries older than PENDING_STALE_HOURS (safety cleanup)
cleanup_stale_pending() {
    local stale_hours="${PENDING_STALE_HOURS:-48}"
    local now
    now=$(date +%s)
    local threshold_seconds=$((stale_hours * 3600))

    local components
    components=$(get_pending_components)

    for component in $components; do
        local first_seen
        first_seen=$(jq -r --arg c "$component" '.[$c].first_seen // empty' "$PENDING_FILE")

        if [[ -z "$first_seen" ]]; then
            continue
        fi

        # Parse first_seen to epoch seconds (cross-platform)
        local first_seen_clean="${first_seen%Z}"
        local first_seen_epoch=""

        if first_seen_epoch=$(date -u -d "$first_seen_clean" +%s 2>/dev/null); then
            : # success
        elif first_seen_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "$first_seen_clean" +%s 2>/dev/null); then
            : # success
        else
            continue
        fi

        local age_seconds=$((now - first_seen_epoch))
        if [[ "$age_seconds" -gt "$threshold_seconds" ]]; then
            local age_hours=$((age_seconds / 3600))
            echo "[pending-state] Removing stale pending entry for $component (${age_hours}h old, threshold: ${stale_hours}h)" >&2
            remove_from_pending "$component"
        fi
    done
}
