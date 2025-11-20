#!/usr/bin/env bash

set -euo pipefail

# Entrypoint script for Konflux Compliance Scanner
# This script orchestrates the compliance scanning and JIRA issue creation workflow

echo "=================================================="
echo "Konflux Compliance Scanner - Starting"
echo "=================================================="
echo "Timestamp: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
echo ""

# Validate required environment variables
validate_env_vars() {
    local missing_vars=()

    # Required for Konflux cluster access
    if [[ -z "${KONFLUX_API_ENDPOINT:-}" ]]; then
        missing_vars+=("KONFLUX_API_ENDPOINT")
    fi

    if [[ -z "${KONFLUX_API_TOKEN:-}" ]]; then
        missing_vars+=("KONFLUX_API_TOKEN")
    fi

    # Required for GitHub API access
    if [[ -z "${GITHUB_TOKEN:-}" ]]; then
        missing_vars+=("GITHUB_TOKEN")
    fi

    # Required for JIRA integration
    if [[ -z "${JIRA_API_TOKEN:-}" ]]; then
        missing_vars+=("JIRA_API_TOKEN")
    fi

    if [[ -z "${JIRA_USER:-}" ]]; then
        missing_vars+=("JIRA_USER")
    fi

    # Required application name
    if [[ -z "${APPLICATION_NAME:-}" ]]; then
        missing_vars+=("APPLICATION_NAME")
    fi

    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        echo "ERROR: Missing required environment variables:"
        printf '  - %s\n' "${missing_vars[@]}"
        echo ""
        echo "Required environment variables:"
        echo "  KONFLUX_API_ENDPOINT - Konflux cluster API server URL (e.g., https://api.konflux.example.com:6443)"
        echo "  KONFLUX_API_TOKEN    - ServiceAccount token for accessing Konflux cluster"
        echo "  GITHUB_TOKEN         - GitHub Personal Access Token for API access"
        echo "  JIRA_API_TOKEN       - JIRA Personal Access Token"
        echo "  JIRA_USER            - JIRA username/email"
        echo "  APPLICATION_NAME     - Konflux application name (e.g., acm-215, mce-29)"
        echo ""
        exit 1
    fi

    echo "✓ All required environment variables are set"
}

# Setup Konflux cluster authentication
setup_konflux_auth() {
    echo ""
    echo "Setting up Konflux cluster authentication..."
    echo "  API Endpoint: $KONFLUX_API_ENDPOINT"

    # Test connectivity to Konflux cluster
    echo "Testing connection to Konflux cluster..."
    if ! kubectl --server="$KONFLUX_API_ENDPOINT" \
                 --token="$KONFLUX_API_TOKEN" \
                 --insecure-skip-tls-verify \
                 get namespaces > /dev/null 2>&1; then
        echo "ERROR: Failed to connect to Konflux cluster"
        echo "  Endpoint: $KONFLUX_API_ENDPOINT"
        echo "  Please verify the endpoint and token are correct"
        exit 1
    fi

    echo "✓ Konflux cluster connection successful"

    # Set default kubectl context for this session
    export KUBECONFIG="/tmp/konflux-kubeconfig-$$"
    kubectl config set-cluster konflux \
        --server="$KONFLUX_API_ENDPOINT" \
        --insecure-skip-tls-verify=true

    kubectl config set-credentials scanner \
        --token="$KONFLUX_API_TOKEN"

    kubectl config set-context konflux \
        --cluster=konflux \
        --user=scanner

    kubectl config use-context konflux

    echo "✓ kubectl configured for Konflux cluster"

    # Verify we can access the tenant namespace
    echo "Verifying access to crt-redhat-acm-tenant namespace..."
    if ! kubectl get namespace crt-redhat-acm-tenant > /dev/null 2>&1; then
        echo "WARNING: Cannot access crt-redhat-acm-tenant namespace"
        echo "  The scanner may have insufficient permissions"
        echo "  Continuing anyway..."
    else
        echo "✓ Access to crt-redhat-acm-tenant verified"
    fi
}

# Setup GitHub token
setup_github_token() {
    echo ""
    echo "Setting up GitHub authentication..."
    echo "$GITHUB_TOKEN" > /workspace/authorization.txt
    chmod 600 /workspace/authorization.txt
    echo "✓ GitHub token configured"
}

# Setup JIRA CLI
setup_jira_cli() {
    echo ""
    echo "Setting up JIRA CLI..."

    # Set JIRA environment variables
    export JIRA_AUTH_TYPE="${JIRA_AUTH_TYPE:-bearer}"
    export JIRA_SERVER="${JIRA_SERVER:-https://issues.redhat.com}"
    export JIRA_INSTALLATION="${JIRA_INSTALLATION:-Local}"
    export JIRA_PROJECT="${JIRA_PROJECT:-ACM}"
    export JIRA_BOARD="${JIRA_BOARD:-None}"

    # Create .env file for create-compliance-jira-issues.sh
    cat > /workspace/.env <<EOF
JIRA_USER=$JIRA_USER
JIRA_API_TOKEN=$JIRA_API_TOKEN
JIRA_AUTH_TYPE=$JIRA_AUTH_TYPE
JIRA_SERVER=$JIRA_SERVER
JIRA_INSTALLATION=$JIRA_INSTALLATION
JIRA_PROJECT=$JIRA_PROJECT
JIRA_BOARD=$JIRA_BOARD
EOF

    chmod 600 /workspace/.env
    echo "✓ JIRA configuration prepared"
}

# Run compliance scan
run_compliance_scan() {
    local app_name="$1"
    local retrigger_flag="${2:-}"

    echo ""
    echo "=================================================="
    echo "Step 1: Running Compliance Scan"
    echo "=================================================="
    echo "Application: $app_name"
    echo "Retrigger failed components: ${retrigger_flag:-no}"
    echo ""

    cd /workspace

    local compliance_cmd="./compliance.sh"
    if [[ -n "$retrigger_flag" ]]; then
        compliance_cmd="$compliance_cmd --retrigger"
    fi

    if [[ -n "${SQUAD_FILTER:-}" ]]; then
        compliance_cmd="$compliance_cmd --squad=$SQUAD_FILTER"
        echo "Filtering by squad: $SQUAD_FILTER"
    fi

    compliance_cmd="$compliance_cmd $app_name"

    echo "Running: $compliance_cmd"
    eval "$compliance_cmd" 2>&1 | tee "/workspace/logs/${app_name}-compliance-scan.log"

    local csv_file="/workspace/data/${app_name}-compliance.csv"
    if [[ ! -f "$csv_file" ]]; then
        echo "ERROR: Compliance CSV file not generated: $csv_file"
        exit 1
    fi

    echo ""
    echo "✓ Compliance scan completed"
    echo "  CSV file: $csv_file"

    # Show summary
    local total_components=$(tail -n +2 "$csv_file" | wc -l | tr -d ' ')
    echo "  Total components scanned: $total_components"
}

# Create/update JIRA issues
create_jira_issues() {
    local app_name="$1"
    local csv_file="/workspace/data/${app_name}-compliance.csv"

    echo ""
    echo "=================================================="
    echo "Step 2: Creating/Updating JIRA Issues"
    echo "=================================================="
    echo ""

    cd /workspace

    local jira_cmd="./create-compliance-jira-issues.sh"

    # Add flags based on environment variables
    if [[ "${SKIP_DUPLICATES:-true}" == "true" ]]; then
        jira_cmd="$jira_cmd --skip-duplicates"
    fi

    if [[ "${AUTO_CLOSE:-true}" == "true" ]]; then
        jira_cmd="$jira_cmd --auto-close"
    fi

    if [[ -n "${JIRA_PRIORITY:-}" ]]; then
        jira_cmd="$jira_cmd --priority $JIRA_PRIORITY"
    fi

    if [[ -n "${JIRA_LABELS:-}" ]]; then
        jira_cmd="$jira_cmd --labels $JIRA_LABELS"
    fi

    # Save JSON output
    local json_output="/workspace/logs/${app_name}-jira-issues.json"
    jira_cmd="$jira_cmd --output-json $json_output"

    jira_cmd="$jira_cmd $csv_file"

    echo "Running: $jira_cmd"
    eval "$jira_cmd" 2>&1 | tee "/workspace/logs/${app_name}-jira-creation.log"

    echo ""
    echo "✓ JIRA issue creation/update completed"

    if [[ -f "$json_output" ]]; then
        echo "  JSON output: $json_output"
    fi
}

# Main execution
main() {
    echo "Configuration:"
    echo "  Application: ${APPLICATION_NAME}"
    echo "  JIRA Project: ${JIRA_PROJECT:-ACM}"
    echo "  JIRA Server: ${JIRA_SERVER:-https://issues.redhat.com}"
    echo "  Skip Duplicates: ${SKIP_DUPLICATES:-true}"
    echo "  Auto-Close: ${AUTO_CLOSE:-true}"
    echo "  Retrigger Failed: ${RETRIGGER_FAILED:-false}"
    if [[ -n "${SQUAD_FILTER:-}" ]]; then
        echo "  Squad Filter: $SQUAD_FILTER"
    fi
    echo ""

    # Validate environment
    validate_env_vars

    # Setup authentication
    setup_konflux_auth
    setup_github_token
    setup_jira_cli

    # Run compliance workflow
    local retrigger_flag=""
    if [[ "${RETRIGGER_FAILED:-false}" == "true" ]]; then
        retrigger_flag="--retrigger"
    fi

    run_compliance_scan "$APPLICATION_NAME" "$retrigger_flag"
    create_jira_issues "$APPLICATION_NAME"

    echo ""
    echo "=================================================="
    echo "Compliance Scan Completed Successfully"
    echo "=================================================="
    echo "Timestamp: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
    echo ""
    echo "Output files:"
    echo "  - CSV: /workspace/data/${APPLICATION_NAME}-compliance.csv"
    echo "  - Scan Log: /workspace/logs/${APPLICATION_NAME}-compliance-scan.log"
    echo "  - JIRA Log: /workspace/logs/${APPLICATION_NAME}-jira-creation.log"
    echo "  - JSON: /workspace/logs/${APPLICATION_NAME}-jira-issues.json"
    echo ""
}

# Run main function
main "$@"
