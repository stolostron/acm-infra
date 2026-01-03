#!/bin/bash
# Context Aggregator Script
#
# Aggregates context from multiple ConfigMaps into a CONTEXTS.md file.
# Used by Argo Workflow to prepare context for AI agents.
#
# Usage:
#   context-aggregator.sh [OPTIONS]
#
# Options:
#   -c, --configmaps   Comma-separated list of ConfigMaps (e.g., "cm1,cm2" or "cm1:key1,cm2")
#   -o, --output       Output file path (default: /workspace/CONTEXTS.md)
#   -n, --namespace    Kubernetes namespace (default: from service account)
#   --dry-run          Print to stdout instead of writing to file
#   -h, --help         Show this help message
#
# Environment:
#   KUBECONFIG         Path to kubeconfig file (for out-of-cluster usage)
#
# Examples:
#   # Basic usage (in-cluster)
#   context-aggregator.sh -c "coding-standards,security-policies"
#
#   # Select specific key from ConfigMap
#   context-aggregator.sh -c "acm-project-context:architecture.md"
#
#   # Out-of-cluster with kubeconfig
#   KUBECONFIG=~/.kube/config context-aggregator.sh -c "coding-standards" --dry-run

set -e

# Default values
CONFIGMAPS=""
OUTPUT_FILE="/workspace/CONTEXTS.md"
NAMESPACE=""
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -c|--configmaps)
      CONFIGMAPS="$2"
      shift 2
      ;;
    -o|--output)
      OUTPUT_FILE="$2"
      shift 2
      ;;
    -n|--namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      head -29 "$0" | tail -27
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Determine namespace
if [ -z "$NAMESPACE" ]; then
  if [ -f /var/run/secrets/kubernetes.io/serviceaccount/namespace ]; then
    NAMESPACE=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
  else
    NAMESPACE="default"
  fi
fi

# Function: Fetch ConfigMap content using kubectl
fetch_configmap() {
  local cm_spec="$1"
  local cm_name="${cm_spec%%:*}"
  local cm_key="${cm_spec#*:}"

  if [ "$cm_name" = "$cm_key" ]; then
    cm_key=""
  fi

  echo "Fetching ConfigMap: $cm_name (key: ${cm_key:-all})" >&2

  # Check if ConfigMap exists
  if ! kubectl get configmap "$cm_name" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "Warning: ConfigMap $cm_name not found" >&2
    return
  fi

  if [ -n "$cm_key" ]; then
    # Get specific key
    local value
    value=$(kubectl get configmap "$cm_name" -n "$NAMESPACE" \
      -o go-template='{{index .data "'"$cm_key"'"}}' 2>/dev/null || echo "")
    if [ -n "$value" ]; then
      echo "<context name=\"$cm_name\" key=\"$cm_key\">"
      echo "$value"
      echo "</context>"
      echo ""
    else
      echo "Warning: Key $cm_key not found in ConfigMap $cm_name" >&2
    fi
  else
    # Get all keys using go-template
    kubectl get configmap "$cm_name" -n "$NAMESPACE" \
      -o go-template='{{range $k, $v := .data}}<context name="'"$cm_name"'" key="{{$k}}">
{{$v}}
</context>

{{end}}'
  fi
}

# Process ConfigMaps and collect output
process_configmaps() {
  if [ -z "$CONFIGMAPS" ]; then
    return
  fi

  echo "Processing ConfigMaps: $CONFIGMAPS" >&2

  echo "$CONFIGMAPS" | tr ',' '\n' | while read -r cm; do
    cm=$(echo "$cm" | xargs)
    if [ -n "$cm" ]; then
      fetch_configmap "$cm"
    fi
  done
}

# Output result
if [ "$DRY_RUN" = true ]; then
  echo "=== Generated CONTEXTS.md ===" >&2
  process_configmaps
  echo "==============================" >&2
else
  mkdir -p "$(dirname "$OUTPUT_FILE")"
  process_configmaps > "$OUTPUT_FILE"
  echo "Written to: $OUTPUT_FILE" >&2
  echo "=== Generated CONTEXTS.md ===" >&2
  cat "$OUTPUT_FILE" >&2
  echo "==============================" >&2
fi
