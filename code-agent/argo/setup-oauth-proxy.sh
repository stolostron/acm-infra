#!/bin/bash
# Setup OAuth Proxy for Argo Server
#
# This script enables OpenShift OAuth authentication for Argo Server UI.
# After running, users must login with OpenShift credentials to access the UI.
#
# Prerequisites:
#   - OpenShift cluster with OAuth configured
#   - Argo Server deployed in 'argo' namespace
#   - kubectl configured with cluster access
#   - openssl installed (for generating cookie secret)
#
# Usage:
#   ./setup-oauth-proxy.sh [--dry-run]
#
# What this script does:
#   1. Generates a random cookie secret for session encryption
#   2. Applies OAuth resources (ServiceAccount annotation, Service, Secret, Route)
#   3. Waits for TLS certificate generation by OpenShift service-ca
#   4. Patches argo-server deployment to add OAuth Proxy sidecar
#   5. Waits for deployment rollout to complete

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="argo"
DRY_RUN=""
ROLLOUT_TIMEOUT="180s"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      DRY_RUN="--dry-run=client -o yaml"
      echo "=== DRY RUN MODE ==="
      shift
      ;;
    --namespace|-n)
      NAMESPACE="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--dry-run] [--namespace|-n NAMESPACE]"
      exit 1
      ;;
  esac
done

echo "Setting up OAuth Proxy for Argo Server..."
echo "Namespace: $NAMESPACE"
echo ""

# Verify argo-server deployment exists
if ! kubectl get deployment argo-server -n "$NAMESPACE" &>/dev/null; then
  echo "Error: argo-server deployment not found in namespace $NAMESPACE"
  exit 1
fi

# Step 1: Generate cookie secret
echo "Step 1: Generating cookie secret..."
COOKIE_SECRET=$(openssl rand -base64 32)
echo "  Cookie secret generated."

# Step 2: Create temp file with substituted secret
TEMP_RESOURCES=$(mktemp)
trap "rm -f $TEMP_RESOURCES" EXIT

sed "s|REPLACE_WITH_RANDOM_STRING|${COOKIE_SECRET}|" \
  "$SCRIPT_DIR/oauth-proxy-resources.yaml" > "$TEMP_RESOURCES"

# Step 3: Apply resources (ServiceAccount, Service, Secret, Route)
echo "Step 2: Applying OAuth Proxy resources..."
if [[ -z "$DRY_RUN" ]]; then
  # Use --force to handle annotation warning on existing resources
  kubectl apply -f "$TEMP_RESOURCES" --force 2>&1 | grep -v "Warning: resource" || true
  echo "  Resources applied."
else
  kubectl apply -f "$TEMP_RESOURCES" $DRY_RUN
fi

# Step 4: Wait for TLS certificate to be generated
if [[ -z "$DRY_RUN" ]]; then
  echo "Step 3: Waiting for TLS certificate..."
  TLS_READY=false
  for i in {1..30}; do
    if kubectl get secret argo-server-tls -n "$NAMESPACE" &>/dev/null; then
      echo "  TLS certificate ready."
      TLS_READY=true
      break
    fi
    echo "  Waiting for certificate... ($i/30)"
    sleep 2
  done

  if [[ "$TLS_READY" != "true" ]]; then
    echo "Warning: TLS certificate not ready after 60 seconds."
    echo "  The deployment may fail. Check if service-ca operator is running."
  fi
fi

# Step 5: Patch the deployment
echo "Step 4: Patching argo-server deployment..."
if [[ -z "$DRY_RUN" ]]; then
  kubectl patch deployment argo-server -n "$NAMESPACE" --type=strategic \
    --patch-file="$SCRIPT_DIR/oauth-proxy-patch.yaml"
  echo "  Deployment patched."
else
  echo "Would patch deployment with:"
  cat "$SCRIPT_DIR/oauth-proxy-patch.yaml"
fi

# Step 6: Wait for rollout
if [[ -z "$DRY_RUN" ]]; then
  echo "Step 5: Waiting for deployment rollout (timeout: $ROLLOUT_TIMEOUT)..."
  if kubectl rollout status deployment/argo-server -n "$NAMESPACE" --timeout="$ROLLOUT_TIMEOUT"; then
    echo "  Rollout complete."
  else
    echo ""
    echo "Warning: Rollout timed out. Checking pod status..."
    kubectl get pods -n "$NAMESPACE" -l app=argo-server
    echo ""
    echo "If pods are stuck, try:"
    echo "  kubectl delete pods -n $NAMESPACE -l app=argo-server"
    echo ""
    echo "Then wait for new pods to be created."
  fi
fi

# Get the route URL
ROUTE_URL=""
if [[ -z "$DRY_RUN" ]]; then
  ROUTE_URL=$(kubectl get route argo-server -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Argo Server is now protected by OpenShift OAuth."
if [[ -n "$ROUTE_URL" ]]; then
  echo "Access: https://$ROUTE_URL"
fi
echo ""
echo "Users will be prompted to login with their OpenShift credentials."
echo ""
echo "To verify:"
echo "  kubectl get pods -n $NAMESPACE -l app=argo-server"
echo "  # Should show 2/2 containers running"
