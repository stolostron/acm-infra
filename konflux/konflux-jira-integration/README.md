# Konflux Compliance Scanner - GitHub Actions

Automatically scan Konflux build compliance and create JIRA issues for failures using GitHub Actions.

## Overview

This solution uses **GitHub Actions scheduled workflows** instead of Docker images and Kubernetes CronJobs, providing a simpler, more maintainable approach.

**Benefits:**
- ✅ No Docker image to build/maintain
- ✅ No container registry needed
- ✅ No Kubernetes infrastructure required
- ✅ Built-in secret management
- ✅ Easy to modify and debug
- ✅ Clear execution logs in GitHub UI
- ✅ Free for public repos
- ✅ **87% faster with tool caching** (15min → 2.5min per run)

## Quick Start

### 1. Configure GitHub Secrets

Go to your repository settings → Secrets and variables → Actions → New repository secret

Add the following secrets:

| Secret Name | Description | Example |
|------------|-------------|---------|
| `KONFLUX_API_ENDPOINT` | Konflux cluster API server URL | `https://api.konflux.example.com:6443` |
| `KONFLUX_API_TOKEN` | ServiceAccount token for Konflux cluster | `eyJhbGciOiJSUzI1...` |
| `JIRA_API_TOKEN` | JIRA Personal Access Token | Your JIRA PAT |
| `JIRA_USER` | JIRA username/email | `your-email@redhat.com` |

**Note:** `GITHUB_TOKEN` is automatically provided by GitHub Actions.

### 2. Enable the Workflow

The workflow is already configured in [.github/workflows/konflux-compliance-scanner.yml](../../.github/workflows/konflux-compliance-scanner.yml)

It will automatically run:
- **Every 15 minutes** - Fast scan (Push, EC, Promotion checks only)
- **Sunday 8:00 AM EST** (13:00 UTC) - Full scan (all 5 compliance dimensions)

### 3. Manual Testing

You can manually trigger the workflow:

1. Go to **Actions** → **Konflux Compliance Scanner**
2. Click **Run workflow**
3. Choose options:
   - Application: `all`, `acm-215`, or `mce-29`
   - Retrigger failed builds: `true` or `false`
   - Create JIRA issues: `true` or `false` (default: `true`)
   - Scan mode: `fast` (Push/EC/Promotion only) or `full` (all 5 dimensions)
   - Retrigger wait minutes: time to wait after retrigger before re-checking (default: `60`)
   - Squad filter: (optional) e.g., `server-foundation`

### 4. View Results

After the workflow completes:
1. Go to **Actions** → select the workflow run
2. Download artifacts: `compliance-results-acm-215`, `compliance-results-mce-29`
3. Check JIRA: https://redhat.atlassian.net (search for labels: `konflux`, `compliance`, `auto-created`)

## Performance Optimization

### Tool Caching (New! 🚀)

The workflows now use GitHub Actions caching to significantly reduce tool download time:

**Performance Improvement:**
- **Before**: ~15 minutes per workflow run (12 matrix jobs × ~75 seconds each)
- **After**: ~2.5 minutes per workflow run (87% reduction!)
  - First matrix job: Downloads and caches tools (~90 seconds)
  - Remaining 11 jobs: Restore from cache (~5 seconds each)

**How it works:**
1. Tools (kubectl, oc, yq, jira-cli) are downloaded once and cached
2. Cache persists for 7 days across workflow runs
3. Subsequent jobs restore tools from cache in seconds
4. Cache automatically invalidates when tool versions change

**Cached tools:**
- `kubectl` v1.31.0 (~45MB)
- `oc` (OpenShift CLI) v4.17.8 (~75MB)
- `yq` v4.44.3 (~4MB)
- `jira-cli` v1.7.0 (~15MB)
- Total cache size: ~140MB (well within 10GB repository limit)

**Note:** `skopeo` continues to be installed via apt-get (not cached due to system dependencies)

**Updating tool versions:**
Edit the environment variables in the workflow files:
```yaml
env:
  KUBECTL_VERSION: "1.31.0"  # Update version here
  OC_VERSION: "4.17.8"
  YQ_VERSION: "4.44.3"
  JIRA_CLI_VERSION: "1.7.0"
  CACHE_VERSION: "v1"        # Bump to force cache refresh
```

**View cache status:**
Go to repository **Actions** → **Caches** to see cached items and their sizes.

## Configuration

### Applications

To add or remove applications, edit the matrix in [.github/workflows/konflux-compliance-scanner.yml](../../.github/workflows/konflux-compliance-scanner.yml):

```yaml
strategy:
  matrix:
    application:
      - acm-215
      - mce-29
      - your-new-app  # Add here
```

### Schedule

To change the schedule, edit the cron expression:

```yaml
on:
  schedule:
    - cron: '*/15 * * * *'  # Fast scan every 15 min
    - cron: '0 13 * * 0'    # Full scan Sunday 8AM EST

    # Examples:
    # Every 30 minutes:        '*/30 * * * *'
    # Every hour:              '0 * * * *'
    # Mon-Fri only at 8am EST: '0 13 * * 1-5'
```

### JIRA Settings

To customize JIRA behavior, edit the environment variables in the workflow:

```yaml
env:
  JIRA_PROJECT: "ACM"           # JIRA project key
  JIRA_PRIORITY: "Critical"     # Issue priority
  JIRA_LABELS: "konflux,compliance,auto-created"
  SKIP_DUPLICATES: "true"       # Skip creating duplicate issues
  AUTO_CLOSE: "true"            # Auto-close resolved issues
  RETRIGGER_WAIT_MINUTES: "60"  # Minutes to wait after retrigger before re-check
  RELEASE_JIRA_COMPONENT: "ACM Architecture"   # JIRA component for release issues
  RELEASE_JIRA_ASSIGNEE: "gparvin@redhat.com"  # Default assignee for release issues
```

## How It Works

```
┌─────────────────────────────────────────────────────────┐
│            GitHub Actions Scheduled Workflow             │
│     (Fast: every 15min / Full: Sunday 8AM EST)          │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│                  Workflow Steps                          │
│                                                          │
│  1. Cache & Install Tools (⚡ Optimized!)               │
│     ├─ Check cache for kubectl, oc, yq, jira-cli       │
│     ├─ Cache hit: Restore in ~5 seconds                │
│     ├─ Cache miss: Download and cache (~90 seconds)    │
│     └─ Install skopeo via apt-get                       │
│     Note: 87% faster with caching enabled!              │
│                                                          │
│  2. Clone Scripts                                       │
│     └─ stolostron/installer-dev-tools                   │
│        ├─ compliance.sh                                 │
│        ├─ create-compliance-jira-issues.sh              │
│        └─ component-squad.yaml                          │
│                                                          │
│  3. Setup Authentication                                │
│     ├─ Konflux cluster (kubectl config)                │
│     ├─ GitHub token                                     │
│     └─ JIRA CLI                                         │
│                                                          │
│  4. Restore Pending State (from GitHub Actions cache)   │
│     └─ Previous scan's pending-failures.json            │
│                                                          │
│  5. Run Compliance Scan                                 │
│     ├─ Scan Konflux components                          │
│     ├─ Fast mode: Push/EC/Promotion only                │
│     ├─ Full mode: all 5 dimensions                      │
│     ├─ Smart denoising: retrigger + wait + re-check     │
│     └─ Generate CSV report                              │
│                                                          │
│  6. Check Release Pipeline Status (full scan only)      │
│     ├─ Query Konflux Release CRDs                       │
│     └─ Generate release-status CSV                      │
│                                                          │
│  7. Create JIRA Issues (confirmed failures only)        │
│     ├─ Parse CSV report                                 │
│     ├─ Map components to squads                         │
│     ├─ Create/update compliance JIRA issues             │
│     ├─ Create release failure JIRA issues               │
│     └─ Auto-close resolved issues                       │
│                                                          │
│  8. Save Pending State + Upload Artifacts               │
│     ├─ pending-failures.json (cached for next run)      │
│     ├─ CSV reports                                      │
│     ├─ Execution logs                                   │
│     └─ JIRA issue JSON                                  │
└─────────────────────────────────────────────────────────┘
```

## Prerequisites

### Required: Konflux Cluster Access

You need to create a ServiceAccount in the Konflux cluster with appropriate permissions.

**On the Konflux cluster**, run:

```bash
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

Save these values and add them as GitHub secrets.

### Required: GitHub Token

The workflow uses the automatic `GITHUB_TOKEN` provided by GitHub Actions. No additional configuration needed.

### Required: JIRA Token

Create a JIRA Personal Access Token:
1. Go to https://id.atlassian.com/manage-profile/security/api-tokens
2. Create new API token
3. Save the token and add it as a GitHub secret

## Troubleshooting

### Workflow Not Running

**Check:**
1. Workflow is enabled (Actions tab → Workflow → Enable workflow)
2. Repository has Actions enabled (Settings → Actions → Allow all actions)
3. Cron schedule is correct (uses UTC time)

### Authentication Failures

**Konflux API:**
```bash
# Test connectivity
curl -k https://your-konflux-endpoint:6443/healthz

# Test with token
kubectl --server=https://your-konflux-endpoint:6443 \
        --token="$KONFLUX_API_TOKEN" \
        --insecure-skip-tls-verify \
        get namespaces
```

**JIRA API:**
```bash
# Test JIRA connection
curl -u "$JIRA_USER:$JIRA_API_TOKEN" \
  https://redhat.atlassian.net/rest/api/2/myself
```

### View Workflow Logs

1. Go to **Actions** tab
2. Select the workflow run
3. Click on the job (e.g., "Scan acm-215")
4. Expand steps to see detailed logs

### Download Artifacts

Artifacts are kept for 30 days:
1. Go to **Actions** → select workflow run
2. Scroll to **Artifacts** section
3. Download `compliance-results-acm-215` or `compliance-results-mce-29`

## Comparison with Docker/Kubernetes Approach

| Aspect | Docker + K8s CronJob | GitHub Actions |
|--------|---------------------|----------------|
| **Complexity** | High (Dockerfile, build, push, deploy) | Low (single YAML file) |
| **Infrastructure** | Requires K8s cluster | None (GitHub-managed) |
| **Maintenance** | Build & push images for updates | Edit workflow file |
| **Secrets** | K8s Secrets | GitHub Secrets |
| **Logs** | `kubectl logs` | GitHub UI |
| **Artifacts** | Requires volume mounts/PVCs | Built-in artifact storage |
| **Cost** | K8s cluster resources | Free (included in GitHub) |
| **Setup Time** | Hours | Minutes |

## Migration from Docker/Kubernetes

If migrating from the Docker/Kubernetes approach:

1. ✅ Configure GitHub secrets (see Quick Start)
2. ✅ Workflow file already exists
3. ✅ Test with manual run first
4. ✅ Monitor first scheduled runs
5. ⚠️ (Optional) Deprecate K8s CronJobs:
   ```bash
   kubectl delete cronjob compliance-scanner-acm-215 -n konflux-compliance
   kubectl delete cronjob compliance-scanner-mce-29 -n konflux-compliance
   ```

## Files

```
.github/workflows/
└── konflux-compliance-scanner.yml       # GitHub Actions workflow

konflux/konflux-jira-integration/scripts/
├── compliance.sh                        # Main compliance scanner
├── create-compliance-jira-issues.sh     # JIRA issue creation/update/close
├── pending-state.sh                     # Smart denoising state management
├── compliance-exceptions.yaml           # Known exemptions (skip checks)
├── github-auth.sh                       # GitHub App authentication
└── ...
```

## Support

**Documentation:**
- This guide
- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [stolostron/installer-dev-tools](https://github.com/stolostron/installer-dev-tools)

**Getting Help:**
1. Check workflow logs in GitHub Actions
2. Review this troubleshooting section
3. Test manually with workflow_dispatch
4. Contact ACM/MCE team

---

**Last Updated**: 2026-03-24
**Version**: 3.0.0 (Smart Denoising + Release Tracking)
**Maintained By**: ACM/MCE Team

## Changelog

### v3.0.0 (2026-03-24)
- Smart denoising: retrigger + wait + re-check before creating JIRA (fixes #22)
- Tiered scanning: fast mode (15min, Push/EC/Promotion) + full mode (weekly, all 5 dimensions)
- Release pipeline tracking via JIRA issues (Component: ACM Architecture, Assignee: Gus Parvin)
- Pending state persistence via GitHub Actions cache
- Concurrency control to prevent overlapping scan runs
- Configurable retrigger wait time (RETRIGGER_WAIT_MINUTES, default: 60)

### v2.1.0 (2025-11-25)
- Added tool caching for 87% performance improvement
- Reduced workflow run time from ~15 minutes to ~2.5 minutes
- Pinned tool versions for reproducible builds
- Cache persists for 7 days across workflow runs

### v2.0.0 (2025-11-21)
- Initial GitHub Actions implementation
- Migrated from Docker/Kubernetes CronJob approach
