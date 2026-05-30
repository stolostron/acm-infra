# ACM/MCE Release Process

Automation tools for creating and managing ACM and MCE releases using Konflux.

## Prerequisites

- `jira` CLI configured with Red Hat Jira access
- `oc` CLI logged into the Konflux cluster (stone-prd-rh01.pg1f.p1.openshiftapps.com)
- `yq` (mikefarah version) and `jq` installed
- `gh` CLI configured with GitHub access
- Git user.name and user.email configured
- Python 3 (for catalog splitting)
- VPN connection to Red Hat network (for GitLab access)

## Quick Start

Run `just help` to see all available recipes and examples.

### Complete Release Workflows

#### Stage Release Workflow

```bash
# 1. Create payload release
just release payload stage acm 2.12.42 --snapshot snapshot-xyz --rc 1 --dry_run false

# 2. Monitor payload release
just check-release <PAYLOAD_RELEASE_NAME>

# 3. Update bundle snapshot (creates PR to operator bundle repo)
just generate-snapshot bundle stage acm 2.12.42 --rc 1 --dry_run false

# 4. Monitor PR merge and wait for pipeline builds
just check-pr bundle-acm <PR_NUMBER>
just check-commit <MERGE_COMMIT_SHA>

# 5. Get bundle snapshot from merged PR
just get-snapshot-from-pr acm <PR_NUMBER>

# 6. Create bundle release  
just release bundle stage acm 2.12.42 --snapshot <BUNDLE_SNAPSHOT> --rc 1 --dry_run false

# 7. Monitor bundle release
just check-release <BUNDLE_RELEASE_NAME>

# 8. Update catalog request (creates PR to catalog repo)
just generate-snapshot catalog stage acm 2.12.42 --rc 1 --dry_run false

# 9. Monitor catalog PR merge and wait for pipeline builds
just check-pr catalog <PR_NUMBER>
just check-commit <MERGE_COMMIT_SHA>

# 10. Get catalog snapshot from merged PR
just get-catalog-snapshot stage acm 2.12.42 <MERGE_COMMIT_SHA>

# 11. Create catalog release (OCP versions auto-detected)
just release catalog stage acm 2.12.42 --snapshot <CATALOG_SNAPSHOT> --rc 1 --dry_run false

# 12. Monitor catalog releases (OCP versions auto-detected)
just check-catalog-releases stage acm 2.12.42 --rc 1

# 13. Retrieve catalog index images (for QE/release thread)
just retrieve-fbc-catalog-images acm 2.12.42 --rc 1

# 14. Create GitLab MR for release files
just create-mr acm 2.12.42
```

#### Prod Release Workflow

**Note:** `--rc` specifies which stage RC to promote from (e.g. `--rc 1` promotes from stage rc1)

```bash
# 1. Promote payload to prod (from stage rc1)
just release payload prod acm 2.12.42 --rc 1 --dry_run false

# 2. Monitor payload release
just check-release <PAYLOAD_RELEASE_NAME>

# 3. Promote bundle to prod (from stage rc1)
just release bundle prod acm 2.12.42 --rc 1 --dry_run false

# 4. Monitor bundle release
just check-release <BUNDLE_RELEASE_NAME>

# 5. Update catalog request for prod (creates PR to catalog repo)
just generate-snapshot catalog prod acm 2.12.42 --dry_run false

# 6. Monitor catalog PR merge and wait for pipeline builds
just check-pr catalog <PR_NUMBER>
just check-commit <MERGE_COMMIT_SHA>

# ⚠️  MANDATORY PAUSE: Send the catalog snapshot to QE in the release thread and
#    WAIT for QE testing to complete before continuing! Do NOT proceed until QE signs off.
# Get the catalog snapshot from the merged PR commit:
just get-catalog-snapshot prod acm 2.12.42 <MERGE_COMMIT_SHA>

# 7. Create catalog release files for STAGE NOT PROD
# Note: RC is 1-prod to generate catalog files. Dry run TRUE is fine.
just release catalog stage acm 2.12.42 --rc 1-prod --snapshot <CATALOG_SNAPSHOT>

# 8. Promote catalog to prod (from stage rc1-prod)
just release catalog prod acm 2.12.42 --rc 1-prod --dry_run false

# 9. Monitor catalog releases
just check-catalog-releases prod acm 2.12.42

# 10. Create GitLab MR for release files
just create-mr acm 2.12.42
```

## Main Workflows

### `release` - Unified Release Workflow

Generate YAML, save to disk, and apply to cluster.

**Syntax:**
```bash
just release <target> <type> <app> <version> [--snapshot <name>] [--rc <N>] [--dry_run false]
```

**Parameters:**
- `target`: "payload", "bundle", or "catalog"
- `type`: "stage" or "prod"
- `app`: "acm" or "mce"
- `version`: Version string (e.g., "2.12.42")
- `--snapshot <name>`: Snapshot name from cluster (required for stage releases)
- `--rc <N>`: RC number (required for stage releases, specifies which stage RC to promote from for prod)
- `--dry_run false`: Apply live to cluster (default: true for dry-run)

**Examples:**
```bash
# Stage payload
just release payload stage acm 2.12.42 --snapshot snapshot-xyz --rc 1 --dry_run false

# Prod bundle (promotes from stage rc1)
just release bundle prod mce 2.10.1 --rc 1 --dry_run false

# Catalog release with auto-detected OCP versions
just release catalog stage acm 2.12.42 --snapshot snapshot-def --rc 1 --dry_run false
```

**What it does:**
1. Clones acm-release-management repo
2. Creates directory structure
3. Fetches snapshot from cluster and saves it
4. Generates the appropriate YAML file (payload/bundle/catalog)
5. Shows the YAML and prompts for confirmation
6. Applies to cluster (dry-run or live)

For **catalog** releases, OCP versions are automatically detected from the catalog config in `acm-mce-operator-catalogs` based on the version.

---

### `generate-snapshot` - Update Snapshot Files and Create PRs

**Syntax:**
```bash
just generate-snapshot <target> <type> <app> <version> [--rc <N>] [--dry_run false]
```

**Targets:**
- `bundle`: Updates operator bundle repository (acm-operator-bundle or mce-operator-bundle)
  - Compares payload snapshot with `latest-snapshot.yaml`
  - If different: replaces file completely
  - If identical: increments `.metadata.generation`
  - Creates PR to release-X.Y or backplane-X.Y branch

- `catalog`: Updates catalog request in acm-mce-operator-catalogs
  - Extracts bundle container image from bundle snapshot
  - Updates `catalog-request.yaml` with new image and timestamp
  - Creates PR to acm-redhat-operators or mce-redhat-operators branch

**RC Selection:**

The `--rc` value selects the *source snapshot* from the previous step, not the RC being created:
- `generate-snapshot bundle` uses `--rc` to find the **payload** snapshot (from `release payload`)
- `generate-snapshot catalog` uses `--rc` to find the **bundle** snapshot (from `release bundle`)

This matters when retrying with a new RC suffix (e.g., `1-3`). If the payload was released under `rc1`, then `generate-snapshot bundle` still uses `--rc 1` to find that payload snapshot. But `release bundle` and subsequent steps use the new RC (`1-3`).

**Examples:**
```bash
# Update bundle snapshot (dry-run)
just generate-snapshot bundle stage acm 2.12.42 --rc 1

# Update catalog request (live)
just generate-snapshot catalog prod mce 2.10.1 --dry_run false
```

**Prerequisites:**
- `release payload` must be run first for bundle target
- `release bundle` must be run first for catalog target

---

## Query & Generate

### Query Recipes

```bash
# Query bugs from Jira
just query-bugs acm 2.12.42              # Exclude bundle bugs
just query-bugs acm 2.12.42 true         # Bundle bugs only

# Query CVEs from Jira
just query-cves mce 2.10.1
```

### Generate Recipes

Generate release YAMLs (output to stdout):

```bash
just generate-payload stage acm 2.12.42 snapshot-xyz --rc 1
just generate-bundle prod mce 2.10.1 snapshot-abc
just generate-catalog acm 2.12.42 snapshot-def 1 "4.14,4.15,4.16"
```

### Apply Recipes

Generate and apply directly to cluster:

```bash
just apply-payload stage acm 2.12.42 snapshot-xyz --rc 1 --dry_run false
just apply-bundle prod mce 2.10.1 snapshot-abc --dry_run false
just apply-catalog stage acm 2.12.42 1 "4.14,4.15" --dry_run false
```

---

## Monitoring

### Monitor Release Status

```bash
# Monitor single release
just check-release stage-publish-acm-212-z42-rc1

# Monitor catalog releases (auto-detects OCP versions)
just check-catalog-releases stage acm 2.12.42 --rc 1

# Monitor catalog releases (manual OCP versions)
just check-catalog-releases stage acm 2.12.42 --rc 1 "4.14-4.16"

# Monitor Konflux commit pipeline
just check-commit abc123def456 acm-operator

# Monitor GitHub PR
just check-pr bundle-mce 3402
just check-pr bundle-acm 1234
just check-pr catalog 5678
```

All monitoring recipes send desktop notifications and play sounds when complete/failed.

---

## Utilities

### `get-snapshot-from-pr` - Get Snapshot from PR

Get snapshot name from a merged PR number.

**Syntax:**
```bash
just get-snapshot-from-pr <app> <pr-number>
```

**Example:**
```bash
just get-snapshot-from-pr mce 3174
# Output: bundle-release-mce-211-20260501-132458-000
```

**How it works:**
1. Looks up merge commit SHA from GitHub PR
2. Finds snapshot with matching `pac.test.appstudio.openshift.io/sha` label

---

### `get-advisory` - Get Advisory from Release

Get advisory ID from release status.

**Syntax:**
```bash
just get-advisory <release-name>
```

**Example:**
```bash
just get-advisory stage-publish-acm-212-z42-rc1
# Output: RHSA-2024:1234
```

---

### `retrieve-fbc-catalog-images` - Get Catalog Images

Retrieve FBC catalog images from releases.

**Syntax:**
```bash
just retrieve-fbc-catalog-images <app> <version> --rc <N> [--ocp_versions <versions>]
```

**Examples:**
```bash
# Auto-detect OCP versions
just retrieve-fbc-catalog-images acm 2.12.42 --rc 1

# Manual OCP versions
just retrieve-fbc-catalog-images acm 2.12.42 --rc 1 --ocp_versions "4.14,4.15,4.16"
```

---

### `verify-catalog-snapshot` - Verify Catalog Content

Verify a catalog snapshot contains the expected app version across all relevant OCP versions. Uses `opm render` to inspect each catalog image.

**Syntax:**
```bash
just verify-catalog-snapshot <type> <app> <version> <snapshot>
```

**Example:**
```bash
just verify-catalog-snapshot stage mce 2.9.4 mce-operator-catalog-stage-20260518-201839-000-kn
```

---

### `get-catalog-snapshot` - Find Converged Catalog Snapshot

Find the catalog snapshot where all required OCP components share a given git revision. Useful after on-push builds complete to find the fully-converged snapshot. Required OCP versions are auto-detected from catalog config.

**Syntax:**
```bash
just get-catalog-snapshot <type> <app> <version> <commit-sha>
```

**Example:**
```bash
just get-catalog-snapshot stage mce 2.11.2 2f0ef36ccd64588a41ce9e8bfdf0e3f379fee85b
```

---

### Other Utilities

```bash
# Clone release management repo and create branch
just clone-release-mgmt stage-release-acm-212-z42-rc1

# Remove cloned repos
just cleanup
```

---

## Configuration

### Variables

Set at the command line:

```bash
# Enable debug output
just debug=true release payload stage acm 2.12.42 snapshot-xyz --rc 1

# Use custom workspace directory
just workspace=/path/to/releases release payload prod acm 2.12.42 snapshot-xyz
```

### Directory Structure

**Production:**
```
acm-release-management/
  ACM/
    ACM-2.12.42/
      snapshot-acm-212-payload-prod-z42.yaml
      acm-212-payload-prod-z42.yaml
      acm-212-bundle-prod-z42.yaml
```

**Stage:**
```
acm-release-management/
  MCE/
    MCE-2.10.1/
      rc1/
        snapshot-mce-210-payload-stage-z1-rc1.yaml
        mce-210-payload-stage-z1-rc1.yaml
        mce-210-bundle-stage-z1-rc1.yaml
        catalogs/
          snapshots/
            snapshot-mce-fbc-ocm-4-14-stage-mce-210-z1-rc1.yaml
            ...
          releases/
            mce-fbc-ocm-4-14-stage-mce-210-z1-rc1.yaml
            ...
```

---

## Important Notes

### Multi-App Ordering (ACM + MCE)

When releasing both ACM and MCE together:
- **Payload and bundle steps** may be run concurrently for ACM and MCE (no dependency between them).
- **Catalog step**: MCE catalog must be fully built and released **before** starting the ACM catalog. This applies to all catalog sub-steps (`generate-snapshot catalog`, PR merge, `release catalog`). Complete the entire MCE catalog flow first, then proceed with ACM.

### Y-stream vs Z-stream Releases

- **Y-stream releases** (X.Y.0): Skip bug/CVE queries, always RHEA type
- **Z-stream releases** (X.Y.Z where Z > 0): Include bugs and CVEs
  - RHSA if CVEs present
  - RHBA if bugs present (no CVEs)
  - RHEA if neither

### Bundle Bugs

Bundle-specific bugs are tracked separately. Use `bundle=true` parameter with `query-bugs` to retrieve them.

### Catalog OCP Versions

For catalog releases, OCP versions are automatically detected from the catalog config files in `acm-mce-operator-catalogs`:
- ACM: `config/acm-redhat-operators-config.yaml`
- MCE: `config/mce-redhat-operators-config.yaml`

The versions are pulled from `.packages[0].versions[]` where `.version` matches `vX.Y`.

Manual override is still possible: `--ocp_versions "4.14,4.15"` or `--ocp_versions "4.14-4.17"`.

### Dry-run by Default

All apply operations default to **dry-run** for safety. Use `--dry_run false` to apply live.

### Git Commits

All commits include `Signed-off-by` and `Co-Authored-By` lines as required by the repository.

---

## Troubleshooting

### "Failed to get git user.email"

Configure your git identity:
```bash
git config user.name "Your Name"
git config user.email "your.email@redhat.com"
```

### "Failed to fetch snapshot from cluster"

Ensure you're logged into the Konflux cluster:
```bash
oc login https://console-openshift-console.apps.stone-prd-rh01.pg1f.p1.openshiftapps.com/
oc project crt-redhat-acm-tenant
oc get snapshot <snapshot-name>
```

### "Not authenticated with GitHub CLI"

Authenticate with gh:
```bash
gh auth login
```

### "Wrong yq version detected"

This tooling requires mikefarah/yq (Go implementation), not python-yq or jq-wrapper.
Install: https://github.com/mikefarah/yq

### "Cannot access GitLab"

Ensure you're connected to Red Hat VPN and have either:
- SSH key configured at https://gitlab.cee.redhat.com/-/profile/keys OR
- Git credentials configured (git config credential.helper)

### "FIXME:" entries in CVE output

Component mapping is missing from the component registry. Add the missing component before proceeding.

### Jira query returns no results

- Verify version format matches Jira (e.g., "acm 2.12.42")
- Check issues exist with correct fixVersion
- For bugs, ensure doc labels or SFDC cases are attached

---

## Getting Help

Run `just help` to see all available recipes with examples.

For issues or feedback, see the repository's issue tracker.
