#!/bin/bash

# Quick script to check GitHub API rate limit

# Source the GitHub authentication library
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/github-auth.sh"

# Get authorization using the shared library
if authorization=$(get_github_authorization 2>/dev/null); then
    # Extract token from "Authorization: Bearer <token>"
    TOKEN="${authorization#Authorization: Bearer }"
    echo "Using authentication method: $(get_github_auth_method)"
else
    echo "❌ No GitHub token found."
    echo "   Set one of the following:"
    echo "   - GH_APP_ID, GH_APP_INSTALLATION_ID, GH_APP_PRIVATE_KEY (for GitHub App)"
    echo "   - GITHUB_TOKEN (for Personal Access Token)"
    echo "   - authorization.txt file"
    exit 1
fi

echo "Checking GitHub API rate limit..."
echo ""

response=$(curl -s -H "Authorization: Bearer $TOKEN" "https://api.github.com/rate_limit")

if [ $? -ne 0 ]; then
    echo "❌ Failed to fetch rate limit"
    exit 1
fi

# Parse response
core_limit=$(echo "$response" | yq -p=json '.rate.limit')
core_remaining=$(echo "$response" | yq -p=json '.rate.remaining')
core_used=$(echo "$response" | yq -p=json '.rate.used')
reset_timestamp=$(echo "$response" | yq -p=json '.rate.reset')

# Calculate reset time
current_time=$(date +%s)
time_until_reset=$((reset_timestamp - current_time))
minutes_until_reset=$((time_until_reset / 60))

# Display results
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "GitHub API Rate Limit Status"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Limit:     $core_limit requests/hour"
echo "  Used:      $core_used"
echo "  Remaining: $core_remaining"
echo ""
echo "  Resets in: ${minutes_until_reset} minutes"
echo "  Reset at:  $(date -r $reset_timestamp '+%Y-%m-%d %H:%M:%S %Z')"
echo ""

# Calculate usage percentage
usage_percent=$((core_used * 100 / core_limit))
remaining_percent=$((core_remaining * 100 / core_limit))

# Visual progress bar
bar_length=50
used_bars=$((usage_percent * bar_length / 100))
remaining_bars=$((bar_length - used_bars))

printf "  Usage: ["
printf "%${used_bars}s" | tr ' ' '█'
printf "%${remaining_bars}s" | tr ' ' '░'
printf "] %d%%\n" "$usage_percent"
echo ""

# Status and warnings
if [ $core_remaining -lt 100 ]; then
    echo "  🔴 CRITICAL: Less than 100 requests remaining!"
    echo "     → Wait $minutes_until_reset minutes before running compliance scan"
elif [ $core_remaining -lt 500 ]; then
    echo "  🟠 WARNING: Less than 500 requests remaining"
    echo "     → Consider waiting for rate limit reset"
elif [ $usage_percent -gt 80 ]; then
    echo "  🟡 CAUTION: Over 80% quota used"
    echo "     → $core_remaining requests remaining should be sufficient for 1-2 scans"
else
    echo "  🟢 HEALTHY: Sufficient quota available"
    estimated_scans=$((core_remaining / 150))
    echo "     → Can run approximately $estimated_scans compliance scans (assuming 150 API calls each)"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
