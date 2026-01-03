# Code Agent

A unified container image providing a comprehensive development environment with multiple AI coding assistants pre-installed.

## Features

- **Multi-AI CLI Support**: Gemini CLI, Claude Code CLI, and OpenCode CLI
- **Multi-Language Runtimes**: Go, Node.js, Python
- **Cloud CLIs**: Google Cloud SDK, AWS CLI v2, kubectl, helm
- **Development Tools**: GitHub CLI, golangci-lint, yq, Docker CLI
- **Shell**: Zsh
- **OpenShift Compatible**: Supports arbitrary UID execution

## Quick Start

### Build the Image

```bash
# Build with local tag for testing
make build-local

# Build with full registry path
make build

# Build with custom tag
make IMAGE_TAG=v1.0.0 build
```

### Run the Container

```bash
# Interactive shell
make shell

# Or run directly
docker run -it --rm \
  -e GOOGLE_API_KEY=your-gemini-key \
  -e ANTHROPIC_API_KEY=your-claude-key \
  -v $(pwd):/workspace \
  code-agent:local
```

## Environment Variables

| Variable | Description | Required For |
|----------|-------------|--------------|
| `GOOGLE_API_KEY` | Gemini API key | Gemini CLI |
| `ANTHROPIC_API_KEY` | Claude/Anthropic API key | Claude Code CLI |
| `OPENAI_API_KEY` | OpenAI API key | OpenCode CLI (optional) |

## AI CLI Usage

### Gemini CLI

```bash
# Interactive mode
gemini

# Non-interactive with prompt
gemini -p "Explain this code"

# Stream JSON output (for automation)
gemini --output-format stream-json -p "task" | gemini-stream-json-reader.sh
```

### Claude Code CLI

```bash
# Interactive mode
claude

# Non-interactive with prompt
claude -p "Refactor this function"

# Autonomous mode (skip permission prompts)
claude --dangerously-skip-permissions -p "task"

# Stream JSON output (for automation)
claude --output-format stream-json --verbose -p "task" | claude-stream-json-reader.sh
```

### OpenCode CLI

```bash
# Interactive mode
opencode

# Run with prompt
opencode run "Fix the bug in main.go"
```

## Included Tools

### Language Runtimes

| Tool | Version |
|------|---------|
| Go | 1.25.5 |
| Node.js | 22.x LTS |
| Python | 3.x |

### Cloud & Container Tools

| Tool | Description |
|------|-------------|
| `gcloud` | Google Cloud SDK |
| `aws` | AWS CLI v2 |
| `kubectl` | Kubernetes CLI |
| `helm` | Kubernetes package manager |
| `docker` | Docker CLI (for DinD scenarios) |

### Development Tools

| Tool | Description |
|------|-------------|
| `gh` | GitHub CLI |
| `golangci-lint` | Go linter |
| `yq` | YAML processor |
| `jq` | JSON processor |
| `git` | Version control |

## Cluster Deployment

### Deployment Order

Deploy resources in this order:

```bash
# 1. Apply shared cluster-scoped resources (once per cluster)
kubectl apply -k code-agent/shared/

# 2. Apply Argo controller configuration
kubectl apply -k code-agent/argo/

# 3. Apply team namespace resources
kubectl apply -k code-agent/server-foundation/
kubectl apply -k code-agent/acm/
```

### ClusterWorkflowTemplate Usage

Three ClusterWorkflowTemplates are available for different use cases:

| Template | Description | AI Model |
|----------|-------------|----------|
| `code-agent-gemini` | Primary template using Gemini CLI | Gemini 3 Pro Preview |
| `code-agent-opencode` | Alternative using OpenCode CLI | Gemini 2.5 Pro |
| `agent-multi-repo-task` | Execute tasks across multiple repos | Gemini 3 Pro Preview |

#### code-agent-gemini

```bash
# Basic usage
argo submit --from clusterworkflowtemplate/code-agent-gemini -n server-foundation

# With custom task
argo submit --from clusterworkflowtemplate/code-agent-gemini -n server-foundation \
  -p task="Analyze this codebase for security issues"

# With GitHub repo and context ConfigMaps
argo submit --from clusterworkflowtemplate/code-agent-gemini -n server-foundation \
  -p repo="https://github.com/stolostron/multicluster-global-hub" \
  -p branch="main" \
  -p context-configmaps="coding-standards,project-context" \
  -p task="Review the code"

# With gVisor container isolation
argo submit --from clusterworkflowtemplate/code-agent-gemini -n server-foundation \
  -p agent-runtimeclass="gvisor" \
  -p task="Analyze codebase"
```

#### code-agent-opencode

Uses OpenCode CLI with Gemini 2.5 Pro (useful when Gemini 3 has compatibility issues):

```bash
argo submit --from clusterworkflowtemplate/code-agent-opencode -n server-foundation \
  -p repo="https://github.com/stolostron/multicluster-global-hub" \
  -p task="Refactor the controller logic"
```

#### agent-multi-repo-task

Execute the same task across multiple repositories and branches in parallel:

```bash
# Single repo
argo submit --from clusterworkflowtemplate/agent-multi-repo-task -n server-foundation \
  -p targets='
  - org: stolostron
    repos: [managedcluster-import-controller]
    branches: [main]
  ' \
  -p task='Run go mod tidy and create a PR'

# Multiple repos and branches (Cartesian product: 2 repos x 2 branches = 4 parallel tasks)
argo submit --from clusterworkflowtemplate/agent-multi-repo-task -n server-foundation \
  -p targets='
  - org: stolostron
    repos: [managedcluster-import-controller, multicloud-operators-foundation]
    branches: [main, backplane-2.10]
  ' \
  -p task='Upgrade Hive API to latest version' \
  -p context-configmaps='context-pr-guide,context-hive-upgrade'

# Multiple organizations
argo submit --from clusterworkflowtemplate/agent-multi-repo-task -n server-foundation \
  -p targets='
  - org: stolostron
    repos: [cluster-proxy]
    branches: [main]
  - org: open-cluster-management
    repos: [api]
    branches: [main]
  ' \
  -p task='Update dependencies'

# With Slack notification
argo submit --from clusterworkflowtemplate/agent-multi-repo-task -n server-foundation \
  -p targets='...' \
  -p task='Run go mod tidy' \
  -p slack-notify='true' \
  -p slack-mentions='<@U123456>'
```

#### Template Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `task` | Task description for the AI agent | "Say hi..." |
| `repo` | GitHub repository URL | "" |
| `branch` | Repository branch | "main" |
| `context-configmaps` | Comma-separated ConfigMap names for context | "" |
| `image` | Container image | quay.io/zhaoxue/code-agent:latest |
| `agent-runtimeclass` | Runtime class (e.g., "gvisor") | "" |
| `targets` | (multi-repo only) YAML list of orgs/repos/branches | "" |
| `slack-notify` | (multi-repo only) Enable Slack notification | "false" |
| `slack-mentions` | (multi-repo only) Slack user/group IDs to mention | "" |

### Workflow Timeout and Cleanup

The workflow templates include cost optimization settings to prevent runaway workflows and automatically clean up completed workflows.

#### TIMEOUT CONFIGURATION

| Setting | Default | Description |
|---------|---------|-------------|
| `activeDeadlineSeconds` | **14400** (4 HOURS) | Maximum workflow execution time. Workflow will be terminated if it exceeds this limit. |

**IMPORTANT**: If your task is expected to run longer than 4 hours, you MUST override this parameter:

```bash
# Example: 8 hours timeout
argo submit --from clusterworkflowtemplate/code-agent-gemini -n server-foundation \
  -p activeDeadlineSeconds="28800" \
  -p task="Long running analysis task"

# Example: 12 hours timeout
argo submit --from clusterworkflowtemplate/code-agent-gemini -n server-foundation \
  -p activeDeadlineSeconds="43200" \
  -p task="Very long running task"
```

Common timeout values:
| Duration | Seconds |
|----------|---------|
| 4 hours (default) | 14400 |
| 8 hours | 28800 |
| 12 hours | 43200 |
| 24 hours | 86400 |

#### TTL CLEANUP STRATEGY

Completed workflows are automatically deleted after the following periods:

| Workflow Status | TTL | Description |
|-----------------|-----|-------------|
| **Success** | **3 DAYS** (259200 seconds) | Successful workflows are cleaned up after 3 days |
| **Failure** | **1 WEEK** (604800 seconds) | Failed workflows are retained longer for debugging |

#### POD GARBAGE COLLECTION

| Setting | Value | Description |
|---------|-------|-------------|
| `podGC.strategy` | OnPodCompletion | Pods are deleted after completion |
| `podGC.deleteDelayDuration` | 30m | Pods are retained for 30 minutes after completion for log inspection |

### Adding a New Team Namespace

To enable code-agent workflows in a new namespace:

1. **Create namespace resources** (copy from `server-foundation/` as template):
   ```yaml
   # namespace.yaml
   apiVersion: v1
   kind: Namespace
   metadata:
     name: my-team
   ```

2. **Create ServiceAccount and RoleBindings** (`rbac.yaml`):
   ```yaml
   apiVersion: v1
   kind: ServiceAccount
   metadata:
     name: argo-workflow
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: argo-workflow-executor-binding
   roleRef:
     apiGroup: rbac.authorization.k8s.io
     kind: ClusterRole
     name: argo-workflow-executor
   subjects:
     - kind: ServiceAccount
       name: argo-workflow
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: argo-workflow-code-agent-binding
   roleRef:
     apiGroup: rbac.authorization.k8s.io
     kind: ClusterRole
     name: code-agent-workflow
   subjects:
     - kind: ServiceAccount
       name: argo-workflow
   ```

3. **Create Secrets** (`secrets.yaml`):
   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: ai-api-keys
   type: Opaque
   stringData:
     GEMINI_API_KEY: "your-gemini-api-key"
   ---
   apiVersion: v1
   kind: Secret
   metadata:
     name: github-credentials
   type: Opaque
   stringData:
     GH_TOKEN: "your-github-token"
     GIT_AUTHOR_NAME: "Your Name"
     GIT_AUTHOR_EMAIL: "your@email.com"
     GIT_COMMITTER_NAME: "Your Name"
     GIT_COMMITTER_EMAIL: "your@email.com"
   ---
   apiVersion: v1
   kind: Secret
   metadata:
     name: s3-artifact-cred
   type: Opaque
   stringData:
     accesskey: "your-aws-access-key"
     secretkey: "your-aws-secret-key"
   ```

4. **Apply resources**:
   ```bash
   kubectl apply -k my-team/
   ```

## Network Security

### NetworkPolicy Overview

Code-agent pods run AI agents (Gemini, Claude) that execute code based on external inputs. To follow the principle of least privilege, NetworkPolicy is deployed to restrict network access and prevent potential security threats.

### Security Threats Mitigated

| Threat | Description | Mitigation |
|--------|-------------|------------|
| **Lateral Movement** | Compromised pod scanning and attacking other cluster services | Block access to private IP ranges (RFC 1918) |
| **Cloud Credential Theft** | Accessing cloud metadata API to steal instance credentials | Block 169.254.169.254 |
| **Internal Service Exploitation** | Accessing databases, caches, or other internal services | Only allow egress to public internet |

### NetworkPolicy Rules Explained

#### 1. Pod Selector

```yaml
spec:
  podSelector: {}  # Empty selector = applies to ALL pods in namespace
  policyTypes:
    - Ingress      # Control incoming traffic
    - Egress       # Control outgoing traffic
```

Once policyTypes are defined, pods are "isolated" by default - only explicitly allowed traffic can pass.

#### 2. Ingress Rules (Incoming Traffic)

```yaml
ingress:
  - from:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: argo-events
```

- Only allows traffic from `argo-events` namespace (for GitHub webhook triggers)
- All other namespaces are blocked from accessing code-agent pods

#### 3. Egress Rules - DNS Resolution

```yaml
egress:
  - to:
      - namespaceSelector: {}
        podSelector:
          matchLabels:
            k8s-app: kube-dns
    ports:
      - protocol: UDP
        port: 53
      - protocol: TCP
        port: 53
```

- Allows DNS resolution via cluster's kube-dns service
- **Required** - without this, pods cannot resolve any domain names

#### 4. Egress Rules - External HTTPS Access

```yaml
egress:
  - to:
      - ipBlock:
          cidr: 0.0.0.0/0      # Allow all public IPs
          except:
            - 10.0.0.0/8       # Block private network Class A
            - 172.16.0.0/12    # Block private network Class B
            - 192.168.0.0/16   # Block private network Class C
            - 169.254.169.254/32  # Block cloud metadata service
    ports:
      - protocol: TCP
        port: 443              # HTTPS
      - protocol: TCP
        port: 80               # HTTP
```

| Rule | Purpose |
|------|---------|
| `cidr: 0.0.0.0/0` | Allow access to all public IPs |
| `except 10.0.0.0/8` | Block cluster internal services (Pod network usually in this range) |
| `except 172.16.0.0/12` | Block another private address range |
| `except 192.168.0.0/16` | Block common internal network addresses |
| `except 169.254.169.254/32` | **Critical**: Block cloud metadata API (AWS/GCP/Azure expose instance credentials here) |
| `port: 443, 80` | Only allow HTTP/HTTPS, not other protocols (SSH, database ports, etc.) |

### IP Address Stability

These IP ranges are **internationally standardized** and will never change:

| IP Range | Type | Standard |
|----------|------|----------|
| `10.0.0.0/8` | RFC 1918 Private Address | IETF Standard |
| `172.16.0.0/12` | RFC 1918 Private Address | IETF Standard |
| `192.168.0.0/16` | RFC 1918 Private Address | IETF Standard |
| `169.254.169.254/32` | Cloud Metadata Address | AWS/GCP/Azure Standard |

External services (GitHub, Gemini, etc.) IPs may change, but this policy allows **all public IPs** so it won't be affected.

### Traffic Flow Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                    External Network (Internet)               │
│  ✅ GitHub API    ✅ Gemini API    ✅ Slack    ✅ S3         │
└─────────────────────────────────────────────────────────────┘
                              ▲
                              │ Only port 443/80 allowed
                              │
┌─────────────────────────────────────────────────────────────┐
│                    code-agent pod                           │
└─────────────────────────────────────────────────────────────┘
                              │
          ┌───────────────────┼───────────────────┐
          ▼                   ▼                   ▼
    ❌ Other Pods        ❌ Metadata Service    ✅ kube-dns
    (10.x.x.x)          (169.254.169.254)      (DNS resolution)
```

### Limitations

- Standard Kubernetes NetworkPolicy cannot filter by domain name
- For stricter domain-based filtering, consider upgrading to Cilium CNI with DNS-aware policies

### Applying NetworkPolicy

NetworkPolicy should be applied per-namespace. Create a NetworkPolicy resource in each team namespace:

```bash
# Apply team namespace (includes NetworkPolicy if defined)
kubectl apply -k code-agent/acm/
kubectl apply -k code-agent/server-foundation/

# Verify policies
kubectl get networkpolicy -n acm
kubectl get networkpolicy -n server-foundation
```

For new team namespaces, create a `network-policy.yaml` based on the rules described above and add it to your kustomization.yaml:

```yaml
resources:
  - namespace.yaml
  - rbac.yaml
  - secrets.yaml
  - network-policy.yaml  # Add NetworkPolicy for your namespace
```

## Kubernetes Deployment

### OpenShift Compatibility

This image is fully compatible with OpenShift's restricted Security Context Constraints (SCC). Key design decisions:

- **HOME set to `/tmp`**: Uses `/tmp` as the home directory since it's world-writable, allowing any arbitrary UID to create config files
- **No fixed UID requirement**: Works with OpenShift's arbitrary UID assignment from project-specific ranges
- **GID 0 (root group)**: User belongs to GID 0, which is standard for OpenShift compatibility

### Security Context

The image runs as non-root and requires minimal security context configuration:

```yaml
# Pod-level securityContext
securityContext:
  runAsNonRoot: true

# Container-level securityContext
containers:
- name: agent
  securityContext:
    allowPrivilegeEscalation: false
    capabilities:
      drop:
        - ALL
    seccompProfile:
      type: RuntimeDefault
```

**Note**: Do NOT set `runAsUser`, `runAsGroup`, or `fsGroup` to fixed values (like 1000). Let OpenShift assign UIDs from the project's allowed range.

### Example Pod Spec

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: code-agent
spec:
  securityContext:
    runAsNonRoot: true
  containers:
  - name: agent
    image: quay.io/stolostron/code-agent:latest
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop:
          - ALL
      seccompProfile:
        type: RuntimeDefault
    env:
    # API keys for AI CLIs
    - name: ANTHROPIC_API_KEY
      valueFrom:
        secretKeyRef:
          name: ai-api-keys
          key: anthropic
    volumeMounts:
    - name: workspace
      mountPath: /workspace
    command:
    - sh
    - -c
    - claude --output-format stream-json --dangerously-skip-permissions -p "Your prompt here"
  volumes:
  - name: workspace
    emptyDir: {}

## gVisor Container Isolation

This image is compatible with gVisor container runtime. All AI CLIs (Node.js-based) and development tools work correctly under gVisor sandboxing.

### Why Use gVisor

gVisor provides an additional layer of isolation between running applications and the host operating system, which is especially important when running AI agents that execute code based on external inputs.

### Installation on OpenShift

To enable gVisor on your OpenShift cluster, see the detailed installation guide in `gvisor/README.md`. Quick start:

```bash
# For worker nodes
oc apply -f gvisor/01-machineconfig-gvisor.yaml

# For master-schedulable clusters
oc apply -f gvisor/01-machineconfig-gvisor-master.yaml

# Create RuntimeClass (after nodes restart)
oc apply -f gvisor/02-runtimeclass-gvisor.yaml
```

### Using gVisor with Workflows

Enable gVisor isolation via the `agent-runtimeclass` parameter:

```bash
argo submit --from clusterworkflowtemplate/code-agent-gemini -n server-foundation \
  -p agent-runtimeclass="gvisor" \
  -p task="Analyze codebase"
```

### Known Limitations

- Docker daemon cannot run inside the container (CLI works with external daemon)
- File I/O operations may have slight performance overhead
- SELinux is disabled in CRI-O configuration (gVisor provides its own sandboxing)
- CRI-O may report container status incorrectly even when running successfully (see gVisor GitHub Issue #10313)

## Argo Workflows Integration

### S3 Artifact Storage Configuration

Argo Workflows requires S3 storage for persisting workflow logs and artifacts. Without this configuration, logs will be lost after workflow completion.

#### Prerequisites

- AWS Account with S3 access
- Argo Workflows installed in your cluster

#### Setup Steps

1. **Create S3 Bucket**

   ```bash
   aws s3 mb s3://your-argo-artifacts --region us-east-1
   ```

2. **Create IAM Policy**

   Create a policy with S3 permissions:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": [
           "s3:PutObject",
           "s3:GetObject",
           "s3:DeleteObject",
           "s3:ListBucket"
         ],
         "Resource": [
           "arn:aws:s3:::your-argo-artifacts",
           "arn:aws:s3:::your-argo-artifacts/*"
         ]
       }
     ]
   }
   ```

3. **Create IAM Access Key**

   - Create an IAM user or use existing one
   - Attach the S3 policy
   - Generate Access Key (select "Application running outside AWS")
   - Save the Access Key ID and Secret Access Key

4. **Configure secrets.yaml**

   Edit `argo/secrets.yaml` and replace placeholders:

   ```yaml
   stringData:
     accesskey: "<YOUR_AWS_ACCESS_KEY_ID>"
     secretkey: "<YOUR_AWS_SECRET_ACCESS_KEY>"
   ```

   **IMPORTANT**: Do not commit real credentials to git!

5. **Deploy Secret**

   ```bash
   kubectl apply -k argo/
   ```

6. **Update Argo Controller ConfigMap**

   ```bash
   kubectl patch configmap workflow-controller-configmap -n argo --type merge -p '{
     "data": {
       "artifactRepository": "archiveLogs: true\ns3:\n  bucket: your-argo-artifacts\n  region: us-east-1\n  endpoint: s3.amazonaws.com\n  accessKeySecret:\n    name: s3-artifact-cred\n    key: accesskey\n  secretKeySecret:\n    name: s3-artifact-cred\n    key: secretkey\n"
     }
   }'
   ```

7. **Restart Argo Controller**

   ```bash
   kubectl rollout restart deployment workflow-controller -n argo
   ```

#### Verify Configuration

```bash
# Check controller is running
kubectl get pod -n argo -l app=workflow-controller

# Verify ConfigMap
kubectl get configmap workflow-controller-configmap -n argo -o jsonpath='{.data.artifactRepository}'
```

#### Per-Namespace Secret Requirement

**Important**: The Argo Controller ConfigMap (Step 6) is a global configuration that specifies the S3 bucket and the secret **name** to use. However, Kubernetes Secrets are namespace-scoped.

When a workflow runs, Argo injects a sidecar container into the workflow pod to upload logs and artifacts to S3. This sidecar needs access to the S3 credentials, so the `s3-artifact-cred` secret must exist in **every namespace** where workflows run.

**Example**: If you have workflows running in `server-foundation` and `acm` namespaces:

```
argo namespace:
  └── workflow-controller-configmap  # Global config (bucket, secret name)

server-foundation namespace:
  └── s3-artifact-cred secret        # Required for workflow pods

acm namespace:
  └── s3-artifact-cred secret        # Required for workflow pods
```

**Adding a new team namespace**:

1. Add `s3-artifact-cred` to the namespace's `secrets.yaml`:

   ```yaml
   ---
   apiVersion: v1
   kind: Secret
   metadata:
     name: s3-artifact-cred
   type: Opaque
   stringData:
     accesskey: "<YOUR_AWS_ACCESS_KEY_ID>"
     secretkey: "<YOUR_AWS_SECRET_ACCESS_KEY>"
   ```

2. Deploy with kustomize:

   ```bash
   kubectl apply -k <team-namespace>/
   ```

## Argo Server Authentication (OpenShift OAuth)

By default, Argo Server UI is exposed without authentication. To secure it with OpenShift OAuth Proxy:

### Prerequisites

- OpenShift cluster (4.x) with OAuth configured
- Argo Server deployed in `argo` namespace
- `kubectl` configured with cluster access
- `openssl` installed (for generating cookie secret)

### Enable OAuth Proxy

```bash
cd code-agent/argo
./setup-oauth-proxy.sh
```

Options:
- `--dry-run`: Preview changes without applying
- `--namespace|-n`: Specify namespace (default: argo)

The script performs these steps:
1. Generates a random cookie secret for session encryption
2. Configures ServiceAccount with OAuth redirect annotation
3. Updates Service to request TLS certificate from OpenShift service-ca
4. Creates Route with reencrypt TLS termination
5. Patches argo-server deployment to add OAuth Proxy sidecar
6. Waits for deployment rollout

After setup, users must login with OpenShift credentials to access the UI.

### Verify Setup

```bash
# Check pods (should show 2/2 containers)
kubectl get pods -n argo -l app=argo-server

# Check route
kubectl get route argo-server -n argo

# Test authentication (should return login page HTML)
curl -sI -k https://$(kubectl get route argo-server -n argo -o jsonpath='{.spec.host}')
```

### Rollback (if needed)

```bash
cd code-agent/argo
./rollback-oauth-proxy.sh
```

This restores the original configuration:
- Removes OAuth Proxy sidecar
- Restores original Service and Route
- Removes OAuth secrets
- **WARNING**: UI becomes accessible without authentication!

### Architecture

```
Before (no auth):
  User → Route (passthrough) → Argo Server (:2746)

After (OAuth):
  User → Route (reencrypt) → OAuth Proxy (:8443) → Argo Server (:2746)
                                   ↓
                          OpenShift OAuth
```

**How it works:**
- OAuth Proxy runs as a sidecar container in the argo-server pod
- All traffic goes through OAuth Proxy first
- Unauthenticated requests are redirected to OpenShift login page
- After login, OAuth Proxy validates the token and forwards requests to Argo Server
- All OpenShift users can access (authorization based on argo-server SA permissions)

### Troubleshooting

**Pods stuck in ContainerCreating:**
```bash
# Check events
kubectl get events -n argo --sort-by='.lastTimestamp' | tail -10

# Force recreate pods
kubectl delete pods -n argo -l app=argo-server
```

**TLS certificate not generated:**
```bash
# Check if service-ca operator is running
kubectl get pods -n openshift-service-ca

# Verify Service annotation
kubectl get svc argo-server -n argo -o jsonpath='{.metadata.annotations}'
```

**OAuth redirect issues:**
```bash
# Check ServiceAccount annotation
kubectl get sa argo-server -n argo -o jsonpath='{.metadata.annotations}'

# Verify Route name matches annotation
kubectl get route argo-server -n argo
```

### Files

```
argo/
├── oauth-proxy-patch.yaml       # Deployment patch (adds sidecar)
├── oauth-proxy-resources.yaml   # SA, Service, Secret, Route configs
├── setup-oauth-proxy.sh         # Enable OAuth script
└── rollback-oauth-proxy.sh      # Rollback script
```

### Multi-Team Environments

This OAuth Proxy setup provides **authentication** (who you are) but not fine-grained **authorization** (what you can do). All authenticated OpenShift users get the same access level.

For multi-team environments with namespace-level RBAC, consider upgrading to Argo SSO mode:
- Configure Argo Server with `--auth-mode=sso`
- Set up OIDC provider (Dex or OpenShift OAuth directly)
- Map OIDC groups to Kubernetes ServiceAccounts

## Make Targets

| Target | Description |
|--------|-------------|
| `make build` | Build and push multi-arch image (amd64 + arm64) |
| `make build-local` | Build image with local tag for testing |
| `make push` | Push image to registry (currently disabled) |
| `make run` | Run container interactively |
| `make shell` | Start a shell in the container |
| `make clean` | Remove locally built images |
| `make help` | Show all available targets |

## Directory Structure

```
code-agent/
├── Dockerfile          # Multi-stage container image definition
├── Makefile            # Build and run automation
├── README.md           # This file
├── shared/             # Cluster-scoped shared resources (apply once per cluster)
│   ├── kustomization.yaml
│   ├── agent-gemini.yaml               # ClusterWorkflowTemplate for Gemini CLI
│   ├── agent-opencode.yaml             # ClusterWorkflowTemplate for OpenCode CLI
│   ├── agent-multi-repo-task.yaml      # Multi-repo parallel task template
│   ├── notify-slack.yaml               # Slack notification template
│   ├── cluster-rbac.yaml               # ClusterRole for code-agent workflows
│   └── namespace-resources/            # Per-namespace resources template
│       ├── kustomization.yaml
│       ├── agent-multi-repo-task-context.yaml  # Default context for multi-repo tasks
│       └── secrets.yaml                # Template for namespace secrets
├── argo/               # Argo Workflows controller configuration
│   ├── kustomization.yaml
│   ├── secrets.yaml                    # S3 credentials (edit before deploying)
│   ├── cluster-rbac.yaml               # ClusterRole for workflow executor
│   ├── oauth-proxy-patch.yaml          # OAuth Proxy deployment patch
│   ├── oauth-proxy-resources.yaml      # OAuth resources (SA, Service, Route)
│   ├── setup-oauth-proxy.sh            # Enable OAuth authentication
│   └── rollback-oauth-proxy.sh         # Rollback OAuth authentication
├── gvisor/             # gVisor container runtime installation for OpenShift
│   ├── README.md                       # Detailed installation guide
│   ├── 01-machineconfig-gvisor.yaml    # MachineConfig for worker nodes
│   ├── 01-machineconfig-gvisor-master.yaml  # MachineConfig for master nodes
│   ├── 02-runtimeclass-gvisor.yaml     # RuntimeClass definition
│   ├── 03-test-pod-gvisor.yaml         # Test pod using nginx
│   └── 04-test-simple.yaml             # Simple test pod using busybox
├── server-foundation/  # Server Foundation team namespace resources
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── rbac.yaml                       # SA and RoleBindings to ClusterRoles
│   ├── README.md                       # Team-specific documentation
│   ├── hive-api-ugprade-workflow.yaml  # Example: Hive API upgrade workflow
│   └── test-simple-workflow.yaml       # Example: Simple test workflow
├── acm/                # ACM team namespace with GitHub event triggers
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── rbac.yaml                       # SA and RoleBindings
│   ├── secrets.yaml                    # API keys and credentials
│   ├── eventbus.yaml                   # Argo Events EventBus
│   ├── eventsource-github.yaml         # GitHub webhook event source
│   ├── route-github.yaml               # OpenShift route for webhooks
│   └── sensor-github.yaml              # Sensor to trigger workflows
└── scripts/
    ├── gemini-stream-json-reader.sh    # Gemini output formatter
    ├── claude-stream-json-reader.sh    # Claude output formatter
    ├── opencode-stream-json-reader.sh  # OpenCode output formatter
    └── context-aggregator.sh           # Context aggregation for CONTEXTS.md
```

## License

See the repository root for license information.
