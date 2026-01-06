# Konflux Compliance Scripts

This directory contains scripts for checking Konflux component compliance status and creating JIRA issues.

## GitHub Authentication

The scripts support multiple GitHub authentication methods with automatic fallback.

### Authentication Priority

```
┌─────────────────────────────────────────────────────────────────┐
│                    Authentication Flow                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. GitHub App (Recommended)                                    │
│     ├── GH_APP_ID                                               │
│     ├── GH_APP_INSTALLATION_ID                                  │
│     └── GH_APP_PRIVATE_KEY                                      │
│              │                                                  │
│              ▼                                                  │
│     ┌───────────────┐    ┌───────────────┐    ┌──────────────┐ │
│     │ Generate JWT  │───►│ Exchange IAT  │───►│ Bearer Token │ │
│     │  (RS256 sign) │    │  (via API)    │    │  (1hr valid) │ │
│     └───────────────┘    └───────────────┘    └──────────────┘ │
│                                                                 │
│  2. Personal Access Token (Fallback)                            │
│     └── GITHUB_TOKEN environment variable                       │
│                                                                 │
│  3. Legacy File (Fallback)                                      │
│     └── authorization.txt file                                  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Option 1: GitHub App Authentication (Recommended)

GitHub App provides better security and higher rate limits (5000 requests/hour vs 5000 for PAT).

**Required Environment Variables:**

| Variable | Description |
|----------|-------------|
| `GH_APP_ID` | The App ID from GitHub App settings page |
| `GH_APP_INSTALLATION_ID` | Installation ID (found in App installation URL) |
| `GH_APP_PRIVATE_KEY` | Full PEM private key content |

> **Note:** We use `GH_APP_*` prefix instead of `GITHUB_*` because GitHub Actions
> reserves the `GITHUB_*` namespace and doesn't allow user secrets with that prefix.

**How it works:**

1. `github-app-iat.sh` generates a JWT signed with the private key
2. JWT is exchanged for an Installation Access Token (IAT) via GitHub API
3. IAT is used as a Bearer token for subsequent API calls
4. Token is cached and auto-refreshed before expiry (1 hour validity)

**Example:**

```bash
export GH_APP_ID="123456"
export GH_APP_INSTALLATION_ID="789012"
export GH_APP_PRIVATE_KEY="$(cat /path/to/private-key.pem)"

./compliance.sh acm-215
```

### Option 2: Personal Access Token

Use a GitHub Personal Access Token (classic or fine-grained).

```bash
export GITHUB_TOKEN="ghp_xxxxxxxxxxxx"

./compliance.sh acm-215
```

### Option 3: Authorization File (Legacy)

Create an `authorization.txt` file in the scripts directory containing your token:

```bash
echo "ghp_xxxxxxxxxxxx" > authorization.txt
chmod 600 authorization.txt

./compliance.sh acm-215
```

## Script Files

| File | Description |
|------|-------------|
| `compliance.sh` | Main compliance checking script |
| `check-rate-limit.sh` | Check GitHub API rate limit status |
| `create-compliance-jira-issues.sh` | Create JIRA issues for failed components |
| `github-auth.sh` | Shared authentication library |
| `github-app-iat.sh` | GitHub App IAT generator |
| `compliance-exceptions.yaml` | Exception rules for compliance checks |

## Obtaining GitHub App Credentials

Before using GitHub App authentication, you need to obtain three pieces of information from your GitHub App settings.

### Step 1: Find the App ID (`GH_APP_ID`)

1. Go to GitHub → Settings → Developer settings → GitHub Apps
2. Click on your GitHub App (e.g., `acm-agent`)
3. On the **General** tab, find **App ID** near the top
4. Copy this numeric value (e.g., `123456`)

> **Note:** You can also use the **Client ID** instead of App ID. GitHub recommends Client ID for new implementations, but both work for JWT authentication.

### Step 2: Find the Installation ID (`GH_APP_INSTALLATION_ID`)

1. Go to GitHub → Settings → Developer settings → GitHub Apps
2. Click on your GitHub App
3. In the left sidebar, click **Install App**
4. Find the organization/account where the app is installed and click **Configure**
5. Look at the URL in your browser:
   ```
   https://github.com/organizations/YOUR_ORG/settings/installations/789012
                                                                    ^^^^^^
                                                         This is your Installation ID
   ```
6. Copy the numeric ID from the URL (e.g., `789012`)

### Step 3: Generate Private Key (`GH_APP_PRIVATE_KEY`)

1. Go to GitHub → Settings → Developer settings → GitHub Apps
2. Click on your GitHub App
3. Scroll down to **Private keys** section
4. Click **Generate a private key**
5. A `.pem` file will be downloaded automatically
6. The file content looks like:
   ```
   -----BEGIN RSA PRIVATE KEY-----
   MIIEpAIBAAKCAQEA...
   ...many lines of base64 encoded data...
   -----END RSA PRIVATE KEY-----
   ```

> **Important:** Keep this private key secure. Never commit it to version control.

### Step 4: Add Secrets to GitHub Repository

1. Go to your GitHub repository → Settings → Secrets and variables → Actions
2. Click **New repository secret** for each:

   | Secret Name | Value |
   |-------------|-------|
   | `GH_APP_ID` | The App ID from Step 1 (e.g., `123456`) |
   | `GH_APP_INSTALLATION_ID` | The Installation ID from Step 2 (e.g., `789012`) |
   | `GH_APP_PRIVATE_KEY` | The **entire content** of the `.pem` file from Step 3 |

   For the private key, paste the complete content including the `-----BEGIN RSA PRIVATE KEY-----` and `-----END RSA PRIVATE KEY-----` lines.

### Step 5: Verify Configuration

After adding the secrets, you can verify the authentication works by:

1. Trigger the workflow manually, or
2. Run locally with environment variables:
   ```bash
   export GH_APP_ID="123456"
   export GH_APP_INSTALLATION_ID="789012"
   export GH_APP_PRIVATE_KEY="$(cat /path/to/private-key.pem)"

   ./check-rate-limit.sh
   ```

Expected output:
```
Using authentication method: github-app
Checking GitHub API rate limit...
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
GitHub API Rate Limit Status
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Limit:     5000 requests/hour
  ...
```

## GitHub Actions Integration

In GitHub Actions, set the following repository secrets:

```yaml
secrets:
  GH_APP_ID: "123456"
  GH_APP_INSTALLATION_ID: "789012"
  GH_APP_PRIVATE_KEY: |
    -----BEGIN RSA PRIVATE KEY-----
    ...
    -----END RSA PRIVATE KEY-----
```

> **Important:** GitHub Actions reserves the `GITHUB_*` namespace for built-in variables.
> User secrets cannot start with `GITHUB_`, so we use `GH_APP_*` prefix instead.

The workflow automatically exports these as environment variables for the scripts.

## Dependencies

- `openssl` - For JWT RS256 signing (standard on Linux/macOS)
- `jq` - For JSON parsing
- `yq` - For YAML parsing
- `curl` - For API calls

## Troubleshooting

### Check Authentication Status

```bash
# Check rate limit (also verifies authentication)
./check-rate-limit.sh
```

### Debug Authentication

```bash
# Source the auth library and check status
source ./github-auth.sh
print_github_auth_status
```

### Common Issues

1. **"No GitHub token found"**
   - Verify environment variables are set correctly
   - Check if `authorization.txt` exists and is readable

2. **"Failed to generate JWT"**
   - Verify `GH_APP_PRIVATE_KEY` contains the full PEM key
   - Check that `openssl` is installed

3. **"Failed to get IAT (HTTP 401)"**
   - Verify `GH_APP_ID` is correct
   - Check that the App is installed on the target organization
   - Verify `GH_APP_INSTALLATION_ID` matches the installation

4. **Rate limit exceeded**
   - Wait for rate limit reset (check with `./check-rate-limit.sh`)
   - GitHub App has 5000 requests/hour per installation
