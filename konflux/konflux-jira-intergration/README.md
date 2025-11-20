# Konflux Compliance Scanner - Complete Deployment Guide

Automatically scan Konflux build compliance and create JIRA issues for failures.

## 📋 Table of Contents

- [Overview](#overview)
- [Quick Start](#quick-start)
- [Prerequisites](#prerequisites)
- [Building the Image](#building-the-image)
- [Configuration](#configuration)
- [Deployment](#deployment)
- [Testing](#testing)
- [Monitoring](#monitoring)
- [Troubleshooting](#troubleshooting)
- [Deployment Checklist](#deployment-checklist)

---

## Overview

This solution provides automated compliance scanning for Konflux builds with JIRA integration:

- **Automated Scanning**: Runs on schedule (8am & 1pm EST, weekdays)
- **JIRA Integration**: Auto-creates/updates issues for failures
- **Multi-Application**: Supports ACM 2.15, MCE 2.9, and more
- **Containerized**: Runs as Kubernetes CronJob

**Components**:
- `compliance.sh` - Scans Konflux components and generates CSV reports
- `create-compliance-jira-issues.sh` - Creates/updates JIRA issues from CSV
- `entrypoint.sh` - Orchestrates the workflow
- `component-squad.yaml` - Maps components to teams

---

## Quick Start

### 1. Build Image

```bash
cd /path/to/konflux-failures-to-jira-issues

# Build and push
./build-and-push.sh \
  --org your-org \
  --tag v1.0.0
```

### 2. Configure Credentials

```bash
kubectl create namespace konflux-compliance

kubectl create secret generic compliance-scanner-credentials \
  --namespace=konflux-compliance \
  --from-literal=konflux-api-endpoint='https://api.konflux.example.com:6443' \
  --from-literal=konflux-api-token='eyJhbGciOiJSUzI1...' \
  --from-literal=github-token='ghp_your_github_token' \
  --from-literal=jira-api-token='your_jira_token' \
  --from-literal=jira-user='your-email@redhat.com'
```

### 3. Update Image Reference

Edit `cronjob.yaml`:
```yaml
image: quay.io/your-org/compliance-scanner:v1.0.0  # Update this
```

### 4. Deploy

```bash
kubectl apply -f cronjob.yaml

# Verify
kubectl get cronjobs -n konflux-compliance
```

### 5. Test

```bash
kubectl create job --from=cronjob/compliance-scanner-acm-215 \
  test-run -n konflux-compliance

kubectl logs -f job/test-run -n konflux-compliance
```

---

## Prerequisites

### Required Tools

- **Docker or Podman** - For building container images
  ```bash
  docker --version
  ```

- **kubectl or oc CLI** - For Kubernetes/OpenShift operations
  ```bash
  kubectl version --client
  ```

- **Container Registry Access** - Quay.io or similar
  ```bash
  docker login quay.io
  ```

- **Kubernetes Cluster Access** - With appropriate permissions
  ```bash
  kubectl cluster-info
  ```

### Required Credentials

#### 1. GitHub Personal Access Token

Create token at: https://github.com/settings/tokens

- **Permissions**: `repo`, `read:org`
- **Format**: `ghp_xxxxxxxxxxxx`

Test:
```bash
curl -H "Authorization: Bearer ghp_your_token" \
  https://api.github.com/user
```

#### 2. JIRA Personal Access Token

Create token at: https://issues.redhat.com (User Settings → Personal Access Tokens)

Test:
```bash
curl -H "Authorization: Bearer your_jira_token" \
  https://issues.redhat.com/rest/api/2/myself
```

#### 3. Konflux Cluster Access

You need to create a ServiceAccount in the Konflux cluster with appropriate permissions.

**On the Konflux cluster**, create:
```bash
# Create namespace and ServiceAccount
kubectl apply -f - <<EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: compliance-scanner-access

---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: external-scanner
  namespace: compliance-scanner-access

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: compliance-scanner-reader
rules:
  - apiGroups: ["appstudio.redhat.com"]
    resources: ["components", "snapshots", "releases", "releaseplans"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["tekton.dev"]
    resources: ["pipelineruns", "taskruns"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["appstudio.redhat.com"]
    resources: ["components"]
    verbs: ["patch", "update"]
  - apiGroups: ["project.openshift.io"]
    resources: ["projects"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["get", "list"]

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: compliance-scanner-reader-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: compliance-scanner-reader
subjects:
  - kind: ServiceAccount
    name: external-scanner
    namespace: compliance-scanner-access

---
apiVersion: v1
kind: Secret
metadata:
  name: external-scanner-token
  namespace: compliance-scanner-access
  annotations:
    kubernetes.io/service-account.name: external-scanner
type: kubernetes.io/service-account-token
EOF
```

**Get the credentials:**
```bash
# Get API endpoint
KONFLUX_API_ENDPOINT=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

# Get token
KONFLUX_API_TOKEN=$(kubectl get secret external-scanner-token -n compliance-scanner-access -o jsonpath='{.data.token}' | base64 -d)

echo "API Endpoint: $KONFLUX_API_ENDPOINT"
echo "Token: $KONFLUX_API_TOKEN"
```

Save these values - you'll need them when creating the secret.

---

## Building the Image

### Login to Container Registry

Before building, ensure you're logged into quay.io:

```bash
docker login quay.io
# Enter your quay.io username and password/token
```

### Using Build Script (Recommended)

**Option 1: Build with your private repository** (Recommended for initial testing)

```bash
# Build and push to your private quay.io repository
./build-and-push.sh \
  --registry quay.io \
  --org zhaoxue \
  --name konflux-jira-integration \
  --tag v1.0.0
```

**Option 2: Build with environment variables**

```bash
IMAGE_REGISTRY=quay.io \
IMAGE_ORG=zhaoxue \
IMAGE_NAME=konflux-jira-integration \
IMAGE_TAG=v1.0.0 \
./build-and-push.sh
```

**Option 3: Build only (no push)**

Useful if you want to test locally first or if you haven't logged in yet:

```bash
./build-and-push.sh \
  --registry quay.io \
  --org zhaoxue \
  --name konflux-jira-integration \
  --tag v1.0.0 \
  --no-push
```

**Option 4: Multi-architecture build**

Build for both amd64 and arm64:

```bash
./build-and-push.sh \
  --registry quay.io \
  --org zhaoxue \
  --name konflux-jira-integration \
  --tag v1.0.0 \
  --platform multi
```

**Option 5: Using podman instead of docker**

```bash
./build-and-push.sh \
  --registry quay.io \
  --org zhaoxue \
  --name konflux-jira-integration \
  --tag v1.0.0 \
  --tool podman
```

**Result**: The image will be pushed to:
- `quay.io/zhaoxue/konflux-jira-integration:v1.0.0`
- `quay.io/zhaoxue/konflux-jira-integration:latest`

**Note**: After pushing, you may need to make the repository public on quay.io if others need to access it:
1. Go to https://quay.io/repository/zhaoxue/konflux-jira-integration
2. Click Settings → Make Public

### Manual Build

```bash
# Build
docker build \
  -t quay.io/your-org/compliance-scanner:latest \
  --platform linux/amd64 \
  .

# Push
docker push quay.io/your-org/compliance-scanner:latest

# Verify
docker pull quay.io/your-org/compliance-scanner:latest
```

### What's Included

The image contains:
- **Base**: Red Hat UBI 9
- **Tools**: kubectl, oc, jq, yq, skopeo, jira-cli, git
- **Scripts**: Fetched from [stolostron/installer-dev-tools](https://github.com/stolostron/installer-dev-tools)
  - `compliance.sh`
  - `create-compliance-jira-issues.sh`
  - `component-squad.yaml`
- **Entrypoint**: Custom workflow orchestrator

---

## Configuration

### CronJob Schedule

Default: 8:00 AM and 1:00 PM EST, Monday-Friday

```yaml
schedule: "0 13,18 * * 1-5"  # UTC times
```

**Customize**:
```yaml
# Daily at 9:00 AM EST (14:00 UTC)
schedule: "0 14 * * *"

# Every 6 hours
schedule: "0 */6 * * *"

# Monday, Wednesday, Friday at 8:00 AM EST
schedule: "0 13 * * 1,3,5"
```

### Environment Variables

**Required** (via Secret):
- `KONFLUX_API_ENDPOINT` - Konflux cluster API server URL
- `KONFLUX_API_TOKEN` - ServiceAccount token for Konflux cluster access
- `GITHUB_TOKEN` - GitHub API access
- `JIRA_API_TOKEN` - JIRA API access
- `JIRA_USER` - JIRA user email
- `APPLICATION_NAME` - Konflux app name (e.g., acm-215)

**Optional** (via ConfigMap):
- `JIRA_PROJECT` - JIRA project key (default: ACM)
- `JIRA_PRIORITY` - Issue priority (default: Critical)
- `JIRA_LABELS` - Issue labels (default: konflux,compliance,auto-created)
- `SKIP_DUPLICATES` - Skip duplicate issues (default: true)
- `AUTO_CLOSE` - Auto-close resolved issues (default: true)
- `RETRIGGER_FAILED` - Auto-retrigger failed builds (default: false)
- `SQUAD_FILTER` - Filter by squad (optional)

### ConfigMap Configuration

Edit in `cronjob.yaml`:

```yaml
data:
  # JIRA Configuration
  jira-server: "https://issues.redhat.com"
  jira-project: "ACM"
  jira-priority: "Critical"
  jira-labels: "konflux,compliance,auto-created"

  # Feature Flags
  skip-duplicates: "true"
  auto-close: "true"
  retrigger-failed: "false"

  # Optional: Squad Filter
  # squad-filter: "server-foundation"
```

### Resource Limits

Adjust based on component count:

```yaml
resources:
  requests:
    memory: "512Mi"   # Medium: 50-150 components
    cpu: "250m"
  limits:
    memory: "1Gi"     # Prevent OOM
    cpu: "500m"
```

**Recommendations**:
- **Small** (<50 components): 256Mi / 100m
- **Medium** (50-150): 512Mi / 250m (default)
- **Large** (>150): 1Gi / 500m

### Adding Applications

Copy existing CronJob and modify:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: compliance-scanner-acm-216  # Change name
spec:
  schedule: "0 13,18 * * 1-5"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: compliance-scanner
              env:
                - name: APPLICATION_NAME
                  value: "acm-216"  # Change app name
              # ... rest stays same
```

---

## Deployment

### Step 1: Create Namespace

```bash
kubectl create namespace konflux-compliance
```

### Step 2: Create Secrets

**Option 1: Using kubectl (Recommended)**

```bash
kubectl create secret generic compliance-scanner-credentials \
  --namespace=konflux-compliance \
  --from-literal=konflux-api-endpoint='https://api.konflux.example.com:6443' \
  --from-literal=konflux-api-token='eyJhbGciOiJSUzI1...' \
  --from-literal=github-token='ghp_xxxxxxxxxxxx' \
  --from-literal=jira-api-token='your_jira_token' \
  --from-literal=jira-user='your-email@redhat.com'
```

**Note**: Get the Konflux cluster credentials from the "Prerequisites" section above.

**Option 2: Edit YAML (Testing only)**

Edit `cronjob.yaml`:
```yaml
stringData:
  konflux-api-endpoint: "https://api.konflux.example.com:6443"
  konflux-api-token: "eyJhbGciOiJSUzI1..."
  github-token: "ghp_your_actual_token"
  jira-api-token: "your_actual_jira_token"
  jira-user: "your-email@redhat.com"
```

### Step 3: Update Image Reference

Edit `cronjob.yaml`:
```yaml
containers:
  - name: compliance-scanner
    image: quay.io/your-org/compliance-scanner:v1.0.0  # Update
```

### Step 4: Deploy Resources

```bash
# Apply full configuration
kubectl apply -f cronjob.yaml

# Verify all resources
kubectl get all -n konflux-compliance
```

### Step 5: Verify Deployment

```bash
# Check CronJobs
kubectl get cronjobs -n konflux-compliance

# Expected output:
# NAME                          SCHEDULE           SUSPEND   ACTIVE
# compliance-scanner-acm-215    0 13,18 * * 1-5    False     0
# compliance-scanner-mce-29     0 13,18 * * 1-5    False     0

# Check RBAC
kubectl get clusterrole compliance-scanner-reader
kubectl get clusterrolebinding compliance-scanner-reader-binding

# Check ServiceAccount
kubectl get serviceaccount compliance-scanner -n konflux-compliance

# Check Secret
kubectl get secret compliance-scanner-credentials -n konflux-compliance

# Check ConfigMap
kubectl get configmap compliance-scanner-config -n konflux-compliance
```

---

## Testing

### Manual Test Run

```bash
# Create test job
kubectl create job --from=cronjob/compliance-scanner-acm-215 \
  test-run-acm-215 -n konflux-compliance

# Watch job status
kubectl get jobs -n konflux-compliance -w

# Get pod name
POD=$(kubectl get pods -n konflux-compliance \
  -l job-name=test-run-acm-215 \
  -o jsonpath='{.items[0].metadata.name}')

# View logs
kubectl logs -f $POD -n konflux-compliance
```

### Expected Output

Successful run shows:
```
==================================================
Konflux Compliance Scanner - Starting
==================================================

✓ All required environment variables are set
✓ Konflux cluster connection successful
✓ kubectl configured for Konflux cluster
✓ Access to crt-redhat-acm-tenant verified
✓ GitHub token configured
✓ JIRA configuration prepared
✓ Compliance scan completed
✓ JIRA issue creation/update completed

Output files:
  - CSV: /workspace/data/acm-215-compliance.csv
  - Scan Log: /workspace/logs/acm-215-compliance-scan.log
  - JIRA Log: /workspace/logs/acm-215-jira-creation.log
  - JSON: /workspace/logs/acm-215-jira-issues.json
```

### Verify JIRA Issues

1. Go to https://issues.redhat.com
2. Search: `labels = konflux AND labels = compliance AND labels = auto-created`
3. Verify issues were created for failed components

### Cleanup Test Job

```bash
kubectl delete job test-run-acm-215 -n konflux-compliance
```

---

## Monitoring

### View Logs

```bash
# Get latest pod
POD=$(kubectl get pods -n konflux-compliance \
  -l app=compliance-scanner,application=acm-215 \
  --sort-by=.metadata.creationTimestamp \
  --no-headers | tail -1 | awk '{print $1}')

# View logs
kubectl logs -f $POD -n konflux-compliance

# View all scanner logs
kubectl logs -l app=compliance-scanner -n konflux-compliance --tail=100
```

### Check Job History

```bash
# Recent jobs
kubectl get jobs -n konflux-compliance \
  --sort-by=.metadata.creationTimestamp

# Successful jobs
kubectl get jobs -n konflux-compliance \
  --field-selector status.successful=1

# Failed jobs
kubectl get jobs -n konflux-compliance \
  --field-selector status.failed=1

# Events
kubectl get events -n konflux-compliance \
  --sort-by=.metadata.creationTimestamp
```

### Useful Aliases

Add to `~/.bashrc` or `~/.zshrc`:

```bash
alias k-compliance='kubectl -n konflux-compliance'
alias k-logs='kubectl logs -n konflux-compliance -l app=compliance-scanner --tail=100'
alias k-jobs='kubectl get jobs -n konflux-compliance --sort-by=.metadata.creationTimestamp'
```

---

## Troubleshooting

### Common Issues

#### 1. Konflux Cluster Connection Failed

**Error**: `ERROR: Failed to connect to Konflux cluster`

**Solutions**:
```bash
# Test endpoint connectivity
curl -k https://your-konflux-endpoint:6443/healthz

# Test with token
kubectl --server=https://your-konflux-endpoint:6443 \
        --token="$KONFLUX_API_TOKEN" \
        --insecure-skip-tls-verify \
        get namespaces

# Check the secret values
kubectl get secret compliance-scanner-credentials -n konflux-compliance -o yaml

# Verify ServiceAccount exists in Konflux cluster
kubectl get serviceaccount external-scanner -n compliance-scanner-access

# Check permissions in Konflux cluster
kubectl auth can-i list pipelineruns.tekton.dev \
  --as=system:serviceaccount:compliance-scanner-access:external-scanner
```

#### 2. ImagePullBackOff

**Error**: `ImagePullBackOff` or `ErrImagePull`

**Solutions**:
```bash
# Verify image exists
docker pull quay.io/your-org/compliance-scanner:latest

# Create imagePullSecret if needed
kubectl create secret docker-registry quay-secret \
  --docker-server=quay.io \
  --docker-username=your-username \
  --docker-password=your-password \
  -n konflux-compliance

# Add to CronJob
spec:
  template:
    spec:
      imagePullSecrets:
        - name: quay-secret
```

#### 3. GitHub API Rate Limit

**Error**: `API rate limit exceeded`

**Solutions**:
```bash
# Check rate limit
curl -H "Authorization: Bearer $GITHUB_TOKEN" \
  https://api.github.com/rate_limit

# Verify token
kubectl get secret compliance-scanner-credentials \
  -n konflux-compliance \
  -o jsonpath='{.data.github-token}' | base64 -d
```

#### 4. JIRA Connection Failed

**Error**: `Failed to initialize JIRA CLI`

**Solutions**:
```bash
# Test JIRA connection
kubectl exec -it $POD -n konflux-compliance -- \
  curl -H "Authorization: Bearer $JIRA_API_TOKEN" \
  https://issues.redhat.com/rest/api/2/myself

# Check JIRA config
kubectl get configmap compliance-scanner-config \
  -n konflux-compliance -o yaml
```

#### 5. OOMKilled

**Error**: `Last State: Terminated (OOMKilled)`

**Solution**: Increase memory limits
```yaml
resources:
  limits:
    memory: "2Gi"  # Increase to 2GB
```

### Debug Tips

#### Enter Running Pod

```bash
# Get running pod
POD=$(kubectl get pods -n konflux-compliance \
  -l app=compliance-scanner \
  --field-selector=status.phase=Running \
  -o name | head -1)

# Exec into pod
kubectl exec -it $POD -n konflux-compliance -- /bin/bash

# Run scripts manually
cd /workspace
./compliance.sh acm-215
./create-compliance-jira-issues.sh data/acm-215-compliance.csv
```

#### View Environment Variables

```bash
kubectl exec $POD -n konflux-compliance -- env | grep -E "JIRA|GITHUB|APPLICATION"
```

#### Check Mounted Configs

```bash
# ConfigMap
kubectl get configmap compliance-scanner-config -n konflux-compliance -o yaml

# Secret (base64 encoded)
kubectl get secret compliance-scanner-credentials \
  -n konflux-compliance \
  -o jsonpath='{.data.github-token}' | base64 -d
```

---

## Maintenance

### Updating Scripts

```bash
# 1. Modify scripts in stolostron/installer-dev-tools repo
# 2. Rebuild image (scripts are fetched during build)
./build-and-push.sh --tag v1.1.0

# 3. Update CronJob
kubectl set image cronjob/compliance-scanner-acm-215 \
  compliance-scanner=quay.io/your-org/compliance-scanner:v1.1.0 \
  -n konflux-compliance
```

### Updating Credentials

```bash
# Update Secret
kubectl create secret generic compliance-scanner-credentials \
  --namespace=konflux-compliance \
  --from-literal=github-token='new_token' \
  --from-literal=jira-api-token='new_jira_token' \
  --from-literal=jira-user='user@redhat.com' \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Updating Configuration

```bash
# Edit ConfigMap
kubectl edit configmap compliance-scanner-config -n konflux-compliance

# Or reapply
kubectl apply -f cronjob.yaml
```

### Regular Checks

**Weekly**:
- Review CronJob execution history
- Check for failed jobs
- Review recent logs

**Monthly**:
- Rotate tokens if needed
- Update image to latest version
- Review and update component-squad.yaml
- Check for new Konflux applications

---

## Deployment Checklist

Use this checklist to ensure complete deployment:

### ✅ Prerequisites

- [ ] Docker/Podman installed
- [ ] kubectl/oc CLI installed
- [ ] Logged into container registry
- [ ] Logged into Kubernetes cluster
- [ ] GitHub token created and tested
- [ ] JIRA token created and tested
- [ ] Konflux cluster access configured (ServiceAccount + token)

### ✅ Build Image

- [ ] Image registry determined (e.g., quay.io/your-org)
- [ ] Image built successfully
- [ ] Image pushed to registry
- [ ] Image pull verified

### ✅ Configure

- [ ] `cronjob.yaml` image reference updated
- [ ] Schedule configured correctly
- [ ] Application names verified
- [ ] Resource limits adjusted
- [ ] ConfigMap settings reviewed
- [ ] Secret created with credentials

### ✅ Deploy

- [ ] Namespace created
- [ ] Resources applied with `kubectl apply -f cronjob.yaml`
- [ ] CronJobs visible with correct schedule
- [ ] ServiceAccount created
- [ ] Secret verified (with Konflux credentials)
- [ ] ConfigMap verified

### ✅ Test

- [ ] Test job created and started
- [ ] Pod status is Running
- [ ] Logs show successful authentication
- [ ] Compliance scan completed
- [ ] JIRA issues created
- [ ] No errors in logs
- [ ] Test job cleaned up

### ✅ Monitor

- [ ] Log viewing aliases configured
- [ ] Can view CronJob execution history
- [ ] Can identify failed jobs
- [ ] (Optional) Alerts configured

### ✅ Documentation

- [ ] Deployment date recorded
- [ ] Deployer name recorded
- [ ] Image version documented
- [ ] Team notified

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Kubernetes CronJob                    │
│  Schedule: 8am & 1pm EST (Mon-Fri)                      │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│                  Container Workflow                      │
│                                                          │
│  1. entrypoint.sh                                       │
│     ├─ Validate environment                             │
│     ├─ Setup Konflux cluster auth                       │
│     ├─ Configure GitHub token                           │
│     └─ Initialize JIRA CLI                              │
│                                                          │
│  2. compliance.sh                                       │
│     ├─ Scan Konflux components                          │
│     ├─ Check build status                               │
│     ├─ Identify failures                                │
│     └─ Generate CSV report                              │
│                                                          │
│  3. create-compliance-jira-issues.sh                    │
│     ├─ Parse CSV report                                 │
│     ├─ Map components to squads                         │
│     ├─ Create/update JIRA issues                        │
│     └─ Close resolved issues                            │
└─────────────────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│                     Outputs                              │
│  - CSV: Component compliance report                     │
│  - Logs: Execution logs                                 │
│  - JSON: JIRA issue details                             │
│  - JIRA: Created/updated issues                         │
└─────────────────────────────────────────────────────────┘
```

---

## Files Overview

```
konflux-failures-to-jira-issues/
├── Dockerfile                 # Container image definition
├── entrypoint.sh              # Workflow orchestrator
├── cronjob.yaml              # Kubernetes deployment manifest
├── build-and-push.sh         # Build automation script
├── README.md                 # This file
├── DEPLOYMENT-CHECKLIST.md   # Detailed checklist (archived)
├── DEPLOYMENT-SUMMARY.md     # Quick summary (archived)
└── README-deployment.md      # Old deployment guide (archived)
```

---

## Support

**Documentation**:
- This comprehensive guide
- Inline comments in scripts
- [stolostron/installer-dev-tools](https://github.com/stolostron/installer-dev-tools)

**Getting Help**:
1. Check [Troubleshooting](#troubleshooting) section
2. Review logs: `kubectl logs -n konflux-compliance ...`
3. Verify credentials and permissions
4. Submit GitHub Issue
5. Contact ACM/MCE team

---

## Contributing

To improve this deployment solution:

1. Test changes in development environment
2. Update documentation
3. Submit pull request
4. Notify team of updates

---

**Last Updated**: 2025-11-20
**Version**: 1.0.0
**Maintained By**: ACM/MCE Team
