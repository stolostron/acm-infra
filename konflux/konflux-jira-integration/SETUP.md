# Setup Guide - GitHub Actions Version

## Quick Setup Checklist

### Step 1: Configure GitHub Secrets (5 minutes)

1. Go to your repository: `https://github.com/YOUR_ORG/acm-infra`
2. Click **Settings** → **Secrets and variables** → **Actions**
3. Click **New repository secret** and add each of these:

#### Secret 1: KONFLUX_API_ENDPOINT
```
Name: KONFLUX_API_ENDPOINT
Value: https://api.konflux.example.com:6443
```
(Replace with your actual Konflux cluster API endpoint)

#### Secret 2: KONFLUX_API_TOKEN
```
Name: KONFLUX_API_TOKEN
Value: eyJhbGciOiJSUzI1NiIsImtpZCI6Ij...
```
(Get this from the Konflux cluster - see below)

#### Secret 3: JIRA_API_TOKEN
```
Name: JIRA_API_TOKEN
Value: YOUR_JIRA_PERSONAL_ACCESS_TOKEN
```
(Create at https://issues.redhat.com → User Settings → Personal Access Tokens)

#### Secret 4: JIRA_USER
```
Name: JIRA_USER
Value: your-email@redhat.com
```

---

### Step 2: Get Konflux Credentials

If you already have Konflux cluster access, get the credentials:

```bash
# Connect to your Konflux cluster first
# Then run these commands:

# Get API endpoint
echo "API Endpoint:"
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'
echo ""

# Get token (if you have a ServiceAccount)
echo "API Token:"
kubectl get secret external-scanner-token -n compliance-scanner-access -o jsonpath='{.data.token}' | base64 -d
echo ""
```

**If you don't have the ServiceAccount yet**, create it on the Konflux cluster:

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

Then get the credentials:
```bash
kubectl get secret external-scanner-token -n compliance-scanner-access -o jsonpath='{.data.token}' | base64 -d
```

---

### Step 3: Test the Workflow (2 minutes)

1. Go to **Actions** tab in your GitHub repo
2. Click **Konflux Compliance Scanner** in the left sidebar
3. Click **Run workflow** (top right)
4. Select options:
   - Branch: `main`
   - Application: `acm-215` (start with one for testing)
   - Retrigger failed builds: `false`
   - Squad filter: (leave empty)
5. Click **Run workflow**

Watch the workflow run - it should complete in 5-10 minutes.

---

### Step 4: Verify Results

After the workflow completes:

1. **Check the workflow logs**:
   - Go to Actions → click on the workflow run
   - Click on "Scan acm-215" job
   - Expand each step to see what happened

2. **Download artifacts**:
   - Scroll to bottom of workflow run page
   - Download `compliance-results-acm-215`
   - Extract and check the CSV and log files

3. **Check JIRA**:
   - Go to https://issues.redhat.com
   - Search: `labels = konflux AND labels = compliance AND labels = auto-created`
   - Verify issues were created for failed components

---

### Step 5: Enable Scheduled Runs

The workflow is already configured to run automatically:
- **8:00 AM EST** (Monday - Friday)
- **1:00 PM EST** (Monday - Friday)

No action needed - it will start running on schedule automatically!

---

## Common Issues

### Issue: "Failed to connect to Konflux cluster"

**Solution**: Check your secrets
```bash
# Test the endpoint
curl -k https://YOUR_KONFLUX_ENDPOINT:6443/healthz

# Test with token
kubectl --server=https://YOUR_KONFLUX_ENDPOINT:6443 \
        --token="YOUR_TOKEN" \
        --insecure-skip-tls-verify \
        get namespaces
```

### Issue: "JIRA authentication failed"

**Solution**: Verify JIRA token
```bash
# Test JIRA API
curl -H "Authorization: Bearer YOUR_JIRA_TOKEN" \
  https://issues.redhat.com/rest/api/2/myself
```

### Issue: "No compliance data found"

**Possible causes**:
- Wrong application name (check: `acm-215` vs `acm-2.15`)
- No components in Konflux for that application
- Permissions issue reading Konflux resources

---

## Next Steps

After successful test:

1. ✅ Let it run on schedule (automatic)
2. ✅ Monitor first few scheduled runs
3. ✅ Check JIRA issues are being created correctly
4. ✅ (Optional) Clean up old Docker/Kubernetes resources if no longer needed:
   ```bash
   kubectl delete cronjob compliance-scanner-acm-215 -n konflux-compliance
   kubectl delete cronjob compliance-scanner-mce-29 -n konflux-compliance
   # Optional: delete the namespace if nothing else uses it
   # kubectl delete namespace konflux-compliance
   ```

---

## Adding More Applications

To scan additional applications, edit `.github/workflows/konflux-compliance-scanner.yml`:

```yaml
strategy:
  fail-fast: false
  matrix:
    application:
      - acm-215
      - mce-29
      - acm-216    # Add new applications here
      - mce-30
```

---

## Customization

### Change Schedule

Edit the cron expression in the workflow file:

```yaml
on:
  schedule:
    # Examples:
    - cron: '0 14 * * *'        # Daily at 9am EST
    - cron: '0 */6 * * *'       # Every 6 hours
    - cron: '0 13 * * 1,3,5'    # Mon/Wed/Fri at 8am EST
```

### Change JIRA Settings

Edit environment variables in the workflow file:

```yaml
env:
  JIRA_PROJECT: "ACM"           # Change project
  JIRA_PRIORITY: "Major"        # Change priority (Critical, Major, Minor)
  JIRA_LABELS: "konflux,compliance,auto-created,my-label"  # Add labels
  AUTO_CLOSE: "false"           # Disable auto-closing resolved issues
```

---

## Need Help?

1. Check workflow logs: Actions → Workflow run → Job → Steps
2. Review [README-github-actions.md](README-github-actions.md)
3. Contact ACM/MCE team

---

**Setup Time**: ~10 minutes
**Maintained By**: ACM/MCE Team
**Last Updated**: 2025-11-21
