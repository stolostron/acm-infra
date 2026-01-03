#!/bin/bash
# Rollback OAuth Proxy for Argo Server
#
# This script removes OAuth Proxy and restores the original Argo Server configuration.
# WARNING: After rollback, the UI will be accessible without authentication!
#
# Usage:
#   ./rollback-oauth-proxy.sh [--namespace|-n NAMESPACE]

set -e

NAMESPACE="argo"
ROLLOUT_TIMEOUT="120s"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --namespace|-n)
      NAMESPACE="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--namespace|-n NAMESPACE]"
      exit 1
      ;;
  esac
done

echo "Rolling back OAuth Proxy for Argo Server..."
echo "Namespace: $NAMESPACE"
echo ""

# Step 1: Restore original deployment configuration
echo "Step 1: Restoring original argo-server deployment..."

# Use JSON patch to:
# - Remove oauth-proxy container (index 1)
# - Restore original args
# - Remove env vars
# - Restore original volumes
# - Restore readiness probe to HTTPS
kubectl patch deployment argo-server -n "$NAMESPACE" --type=json -p='[
  {"op": "remove", "path": "/spec/template/spec/containers/1"},
  {"op": "replace", "path": "/spec/template/spec/containers/0/args", "value": ["server", "--auth-mode", "server", "--auth-mode", "client"]},
  {"op": "remove", "path": "/spec/template/spec/containers/0/env"},
  {"op": "replace", "path": "/spec/template/spec/containers/0/readinessProbe", "value": {"httpGet": {"path": "/", "port": 2746, "scheme": "HTTPS"}, "initialDelaySeconds": 10, "periodSeconds": 20}},
  {"op": "replace", "path": "/spec/template/spec/volumes", "value": [{"name": "tmp", "emptyDir": {}}]}
]' 2>/dev/null && echo "  Deployment patched." || echo "  Some patches may have already been applied."

# Step 2: Restore original Service
echo "Step 2: Restoring original Service..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: argo-server
  namespace: $NAMESPACE
spec:
  ports:
    - name: web
      port: 2746
      targetPort: 2746
      protocol: TCP
  selector:
    app: argo-server
  type: ClusterIP
EOF
echo "  Service restored."

# Step 3: Restore original Route
echo "Step 3: Restoring original Route..."
kubectl apply -f - <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: argo-server
  namespace: $NAMESPACE
spec:
  port:
    targetPort: 2746
  tls:
    termination: passthrough
  to:
    kind: Service
    name: argo-server
    weight: 100
EOF
echo "  Route restored."

# Step 4: Remove OAuth-related secrets
echo "Step 4: Cleaning up OAuth secrets..."
kubectl delete secret argo-server-oauth-cookie -n "$NAMESPACE" --ignore-not-found
kubectl delete secret argo-server-tls -n "$NAMESPACE" --ignore-not-found
echo "  Secrets removed."

# Step 5: Remove OAuth annotation from ServiceAccount
echo "Step 5: Removing OAuth annotation from ServiceAccount..."
kubectl annotate sa argo-server -n "$NAMESPACE" \
  serviceaccounts.openshift.io/oauth-redirectreference.argo- \
  2>/dev/null && echo "  Annotation removed." || echo "  Annotation already removed."

# Step 6: Wait for rollout
echo "Step 6: Waiting for deployment rollout..."
if kubectl rollout status deployment/argo-server -n "$NAMESPACE" --timeout="$ROLLOUT_TIMEOUT"; then
  echo "  Rollout complete."
else
  echo ""
  echo "Warning: Rollout timed out. Checking pod status..."
  kubectl get pods -n "$NAMESPACE" -l app=argo-server
  echo ""
  echo "If pods are stuck, try:"
  echo "  kubectl delete pods -n $NAMESPACE -l app=argo-server"
fi

# Get the route URL
ROUTE_URL=$(kubectl get route argo-server -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

echo ""
echo "=== Rollback Complete ==="
echo ""
echo "Argo Server has been restored to the original configuration."
if [[ -n "$ROUTE_URL" ]]; then
  echo "Access: https://$ROUTE_URL"
fi
echo ""
echo "WARNING: The UI is now accessible without authentication!"
echo ""
echo "To verify:"
echo "  kubectl get pods -n $NAMESPACE -l app=argo-server"
echo "  # Should show 1/1 container running"
