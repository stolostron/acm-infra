#!/usr/bin/env bash
# Reassign compliance JIRA issues from the triage queue (ACM Architecture)
# to the correct squad component based on component-registry.yaml.
#
# Usage:
#   reassign-compliance-issues.sh [--dry-run] [--release <version>] [--app <app_name>]
#
# The script:
#   1. Queries JIRA for open compliance issues with component "ACM Architecture"
#   2. Extracts the Konflux component name from the "component:<name>" label
#   3. Looks up the JIRA component in component-registry.yaml
#   4. Updates the JIRA issue's Component field to the correct squad
#
# Environment:
#   JIRA_PROJECT       - JIRA project key (default: ACM)
#   JIRA_SERVER        - JIRA server URL (default: https://redhat.atlassian.net)
#   JIRA_USER          - JIRA username (email) for REST API auth
#   JIRA_API_TOKEN     - JIRA API token for REST API auth
#   COMPLIANCE_JIRA_COMPONENT - Triage queue component (default: ACM Architecture)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
JIRA_PROJECT="${JIRA_PROJECT:-ACM}"
JIRA_SERVER="${JIRA_SERVER:-https://redhat.atlassian.net}"
TRIAGE_COMPONENT="${COMPLIANCE_JIRA_COMPONENT:-ACM Architecture}"
DRY_RUN=false
RELEASE_FILTER=""
APP_FILTER=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Reassign compliance JIRA issues from the triage queue to the correct squad.

Options:
  --dry-run              Show what would be changed without making updates
  --release <version>    Filter issues by affects-version (e.g., 2.13, 2.14)
  --app <app_name>       Filter issues by application name in summary (e.g., acm-217)
  -h, --help             Show this help message

Examples:
  $(basename "$0") --dry-run
  $(basename "$0") --release 2.13
  $(basename "$0") --app acm-217 --dry-run
EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)    DRY_RUN=true; shift ;;
        --release)    RELEASE_FILTER="$2"; shift 2 ;;
        --app)        APP_FILTER="$2"; shift 2 ;;
        -h|--help)    usage ;;
        *)            error "Unknown option: $1"; usage ;;
    esac
done

# Look up JIRA component for a Konflux component name using component-registry.yaml
get_jira_component() {
    local component_name="$1"
    local config_file="$SCRIPT_DIR/../../../acm-config/product/component-registry.yaml"

    if [[ ! -f "$config_file" ]]; then
        warn "component-registry.yaml not found at $config_file"
        echo ""
        return
    fi

    # Strip version suffix (e.g., -210, -215, -27, -29)
    local base_name
    base_name=$(echo "$component_name" | sed 's/-[0-9][0-9]*$//')

    # Query by konflux_component field
    local jira_component
    jira_component=$(yq ".components[] | select(.konflux_component == \"$component_name\") | .jira_component" "$config_file" 2>/dev/null)

    # Try base name if no exact match
    if [[ -z "$jira_component" || "$jira_component" == "null" ]] && [[ "$base_name" != "$component_name" ]]; then
        jira_component=$(yq ".components[] | select(.konflux_component == \"$base_name\") | .jira_component" "$config_file" 2>/dev/null)
    fi

    # Filter out empty/null
    echo "$jira_component" | grep -v '^$' | grep -v '^null$' | head -n 1
}

# Extract component name from "component:<name>" label
extract_component_from_labels() {
    local labels="$1"
    echo "$labels" | tr ',' '\n' | grep '^component:' | sed 's/^component://' | head -n 1
}

main() {
    info "Reassigning compliance JIRA issues from '$TRIAGE_COMPONENT' to correct squads"
    [[ "$DRY_RUN" == true ]] && info "DRY RUN mode — no changes will be made"

    # Build JQL query
    local jql="project=$JIRA_PROJECT AND labels=compliance AND labels=auto-created AND component=\"$TRIAGE_COMPONENT\" AND status NOT IN (Closed,Done,Resolved)"

    if [[ -n "$RELEASE_FILTER" ]]; then
        jql="$jql AND affectedVersion=\"$RELEASE_FILTER\""
        info "Filtering by release: $RELEASE_FILTER"
    fi

    if [[ -n "$APP_FILTER" ]]; then
        jql="$jql AND summary~\"[$APP_FILTER]\""
        info "Filtering by application: $APP_FILTER"
    fi

    info "JQL: $jql"

    # Query JIRA for matching issues
    local issues
    issues=$(jira issue list --jql "$jql" --plain --no-headers --columns KEY,LABELS 2>/dev/null || echo "")

    if [[ -z "$issues" ]]; then
        info "No issues found in triage queue matching the criteria"
        return 0
    fi

    local total=0 reassigned=0 skipped=0 failed=0

    while IFS=$'\t' read -r issue_key labels; do
        total=$((total + 1))
        issue_key=$(echo "$issue_key" | xargs)
        labels=$(echo "$labels" | xargs)

        # Extract Konflux component name from labels
        local component_name
        component_name=$(extract_component_from_labels "$labels")

        if [[ -z "$component_name" ]]; then
            warn "$issue_key: No component:<name> label found, skipping"
            skipped=$((skipped + 1))
            continue
        fi

        # Look up the correct JIRA component
        local target_component
        target_component=$(get_jira_component "$component_name")

        if [[ -z "$target_component" ]]; then
            warn "$issue_key: No JIRA component mapping for '$component_name', skipping"
            skipped=$((skipped + 1))
            continue
        fi

        if [[ "$target_component" == "$TRIAGE_COMPONENT" ]]; then
            info "$issue_key: Already mapped to '$TRIAGE_COMPONENT', skipping"
            skipped=$((skipped + 1))
            continue
        fi

        if [[ "$DRY_RUN" == true ]]; then
            info "$issue_key: Would reassign component '$TRIAGE_COMPONENT' -> '$target_component' (from $component_name)"
            reassigned=$((reassigned + 1))
        else
            # Use JIRA REST API to SET (replace) the component, not append
            local http_status
            http_status=$(curl -s -o /dev/null -w "%{http_code}" \
                --connect-timeout 10 --max-time 30 \
                -u "$JIRA_USER:$JIRA_API_TOKEN" \
                -H "Content-Type: application/json" \
                -X PUT \
                "$JIRA_SERVER/rest/api/2/issue/$issue_key" \
                -d "{\"fields\":{\"components\":[{\"name\":\"$target_component\"}]}}")

            if [[ "$http_status" == "204" || "$http_status" == "200" ]]; then
                success "$issue_key: Reassigned component '$TRIAGE_COMPONENT' -> '$target_component' (from $component_name)"
                reassigned=$((reassigned + 1))
            else
                error "$issue_key: Failed to reassign component to '$target_component' (HTTP $http_status)"
                failed=$((failed + 1))
            fi
        fi
    done <<< "$issues"

    echo ""
    info "Summary: $total issues found, $reassigned reassigned, $skipped skipped, $failed failed"
}

main
