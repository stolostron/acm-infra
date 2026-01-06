#!/usr/bin/env bash
# GitHub Authentication Library
#
# This library provides unified GitHub authentication with multiple fallback methods.
# Source this file in your script to use the authentication functions.
#
# Authentication Priority:
#   1. GitHub App (if GITHUB_APP_ID, GITHUB_INSTALLATION_ID, GITHUB_APP_PRIVATE_KEY are set)
#   2. GITHUB_TOKEN environment variable
#   3. authorization.txt file (legacy)
#
# Usage:
#   source "$(dirname "$0")/github-auth.sh"
#   if authorization=$(get_github_authorization); then
#       curl -H "$authorization" https://api.github.com/...
#   fi

# Prevent multiple sourcing
if [[ -n "${_GITHUB_AUTH_SOURCED:-}" ]]; then
    return 0
fi
_GITHUB_AUTH_SOURCED=1

# Get the directory where this script is located
_GITHUB_AUTH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Token caching variables (global)
_GITHUB_IAT_TOKEN=""
_GITHUB_IAT_EXPIRY=0
_GITHUB_AUTH_METHOD=""

# Log message to stderr (for debugging)
_github_auth_log() {
    echo "[github-auth] $1" >&2
}

# Check if GitHub App credentials are available
# Note: We use GH_APP_* prefix instead of GITHUB_* because GitHub Actions
#       reserves the GITHUB_* namespace and doesn't allow user secrets with that prefix.
github_app_credentials_available() {
    [[ -n "${GH_APP_ID:-}" && \
       -n "${GH_APP_INSTALLATION_ID:-}" && \
       -n "${GH_APP_PRIVATE_KEY:-}" ]]
}

# Get a fresh IAT using the github-app-iat.sh script
_generate_fresh_iat() {
    local iat_script="${_GITHUB_AUTH_SCRIPT_DIR}/github-app-iat.sh"

    if [[ ! -x "$iat_script" ]]; then
        _github_auth_log "Error: IAT script not found or not executable: $iat_script"
        return 1
    fi

    local token
    token=$("$iat_script" 2>&1)
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        _github_auth_log "Error generating IAT: $token"
        return 1
    fi

    if [[ -z "$token" ]]; then
        _github_auth_log "Error: IAT script returned empty token"
        return 1
    fi

    printf '%s' "$token"
}

# Get cached IAT or generate a new one
# Returns: IAT token on stdout
get_github_app_token() {
    local now
    now=$(date +%s)

    # Check if cached token is still valid (with 5-minute buffer)
    if [[ -n "$_GITHUB_IAT_TOKEN" && $_GITHUB_IAT_EXPIRY -gt $((now + 300)) ]]; then
        printf '%s' "$_GITHUB_IAT_TOKEN"
        return 0
    fi

    # Generate fresh token
    _github_auth_log "Generating new GitHub App IAT..."
    local token
    token=$(_generate_fresh_iat)

    if [[ -z "$token" ]]; then
        return 1
    fi

    # Cache token with 1-hour expiry (IAT validity period)
    _GITHUB_IAT_TOKEN="$token"
    _GITHUB_IAT_EXPIRY=$((now + 3600))

    printf '%s' "$token"
}

# Get GitHub authorization header
# Returns: "Authorization: Bearer <token>" on stdout
# Exit code: 0 on success, 1 if no auth available
get_github_authorization() {
    local token=""

    # Priority 1: GitHub App authentication
    if github_app_credentials_available; then
        _github_auth_log "Attempting GitHub App authentication (App ID: $GH_APP_ID)"
        token=$(get_github_app_token)
        if [[ -n "$token" ]]; then
            _GITHUB_AUTH_METHOD="github-app"
            printf 'Authorization: Bearer %s' "$token"
            return 0
        else
            _github_auth_log "GitHub App auth failed, trying fallback methods..."
        fi
    fi

    # Priority 2: GITHUB_TOKEN environment variable
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        _github_auth_log "Using GITHUB_TOKEN environment variable"
        _GITHUB_AUTH_METHOD="github-token"
        printf 'Authorization: Bearer %s' "$GITHUB_TOKEN"
        return 0
    fi

    # Priority 3: authorization.txt file (legacy)
    # Check in current directory and script directory
    local auth_file=""
    if [[ -f "authorization.txt" ]]; then
        auth_file="authorization.txt"
    elif [[ -f "${_GITHUB_AUTH_SCRIPT_DIR}/authorization.txt" ]]; then
        auth_file="${_GITHUB_AUTH_SCRIPT_DIR}/authorization.txt"
    fi

    if [[ -n "$auth_file" ]]; then
        _github_auth_log "Using authorization.txt file: $auth_file"
        _GITHUB_AUTH_METHOD="authorization-file"
        printf 'Authorization: Bearer %s' "$(cat "$auth_file")"
        return 0
    fi

    # No authentication available
    _github_auth_log "Warning: No GitHub authentication configured"
    _GITHUB_AUTH_METHOD=""
    return 1
}

# Refresh the authorization if using GitHub App and token is expiring soon
# This should be called periodically during long-running operations
# Updates the global authorization variable if passed by name
refresh_github_auth_if_needed() {
    # Only applicable for GitHub App auth
    if [[ "$_GITHUB_AUTH_METHOD" != "github-app" ]]; then
        return 0
    fi

    local now
    now=$(date +%s)

    # Refresh if expiring within 5 minutes
    if [[ $_GITHUB_IAT_EXPIRY -le $((now + 300)) ]]; then
        _github_auth_log "Refreshing GitHub App token..."
        local token
        token=$(get_github_app_token)
        if [[ -n "$token" ]]; then
            # Update cached expiry
            _GITHUB_IAT_EXPIRY=$((now + 3600))
            return 0
        else
            _github_auth_log "Warning: Failed to refresh token"
            return 1
        fi
    fi

    return 0
}

# Get the current authentication method being used
# Returns: "github-app", "github-token", "authorization-file", or empty string
get_github_auth_method() {
    printf '%s' "$_GITHUB_AUTH_METHOD"
}

# Print authentication status (for debugging)
print_github_auth_status() {
    echo "GitHub Authentication Status:"
    echo "  Method: ${_GITHUB_AUTH_METHOD:-none}"

    if github_app_credentials_available; then
        echo "  GitHub App ID: $GH_APP_ID"
        echo "  Installation ID: $GH_APP_INSTALLATION_ID"
        echo "  Private Key: [${#GH_APP_PRIVATE_KEY} bytes]"
        if [[ -n "$_GITHUB_IAT_TOKEN" ]]; then
            local now
            now=$(date +%s)
            local remaining=$(((_GITHUB_IAT_EXPIRY - now) / 60))
            echo "  IAT Token: [cached, expires in ~${remaining}m]"
        fi
    fi

    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        echo "  GITHUB_TOKEN: [${#GITHUB_TOKEN} chars]"
    fi

    if [[ -f "authorization.txt" ]]; then
        echo "  authorization.txt: found in current directory"
    elif [[ -f "${_GITHUB_AUTH_SCRIPT_DIR}/authorization.txt" ]]; then
        echo "  authorization.txt: found in script directory"
    fi
}
