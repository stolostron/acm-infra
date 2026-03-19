# ACM/MCE Release Process

Automation tools for creating and managing ACM and MCE releases using Konflux.

## Prerequisites

- `jira` CLI configured with Red Hat Jira access
- `oc` CLI logged into the Konflux cluster
- `yq` and `jq` installed
- `gh` CLI configured with GitHub access
- Git user.name and user.email configured

## Quick Start

The main workflow uses the `release` recipe to generate, save, and apply release files:

```bash
# Stage release (dry-run by default)
just release payload stage acm 2.15.1 snapshot-release-acm-215-abc123 1

# Production release (live)
just release payload prod acm 2.15.1 snapshot-release-acm-215-xyz789 "" skip_confirm=true dry_run=false
```

## Parameter Syntax

Recipes accept both positional and named parameters:

- **Positional parameters** (required): Must be provided in order
  - Example: `release payload prod acm 2.15.1 snapshot-xyz`

- **Named parameters** (optional): Can be provided in any order using `name=value` syntax
  - Example: `dry_run=false skip_confirm=true rc=4`
  - You can skip parameters that have defaults
  - Order doesn't matter for named parameters

**Full example:**
```bash
# These are equivalent:
just release payload stage acm 2.15.1 snapshot-xyz rc=4 skip_confirm=true dry_run=false
just release payload stage acm 2.15.1 snapshot-xyz dry_run=false rc=4 skip_confirm=true
just release payload stage acm 2.15.1 snapshot-xyz skip_confirm=true dry_run=false rc=4

# Skip parameters with defaults (rc defaults to "")
just release payload prod acm 2.15.1 snapshot-xyz skip_confirm=true dry_run=false
```

## Available Recipes

### Main Release Workflow

#### `release`
Generate YAML, save to disk, and apply to cluster.

**Syntax:**
```bash
just release <target> <type> <app> <version> <snapshot> [rc] [skip_confirm] [dry_run]
```

**Parameters:**
- `target`: "payload", "bundle", or "catalog"
- `type`: "stage" or "prod"
- `app`: "acm" or "mce"
- `version`: Version string (e.g., "2.15.1")
- `snapshot`: Snapshot name from cluster
- `rc`: RC number (required for stage releases)
- `skip_confirm`: "true" to skip confirmation prompt (default: "false")
- `dry_run`: "true" for dry-run, "false" for live apply (default: "true")

**Examples:**
```bash
# Stage payload with RC1 (dry-run)
just release payload stage acm 2.15.1 snapshot-xyz 1

# Prod bundle (live, skip confirm)
just release bundle prod mce 2.10.1 snapshot-abc "" skip_confirm=true dry_run=false

# Prod catalog (dry-run with confirm)
just release catalog prod acm 2.15.1 snapshot-xyz
```

**What it does:**
1. Creates directory structure: `ACM/ACM-2.15.1/` or `ACM/ACM-2.15.1/rc1/`
2. Fetches snapshot from cluster and saves it
3. Generates the appropriate YAML file
4. Shows the YAML to you
5. Prompts for confirmation (unless skipped)
6. Applies to cluster (dry-run or live)

### Query Recipes

#### `query-bugs`
Query bugs from Jira for a specific version.

```bash
just query-bugs <app> <version> [bundle]
```

**Parameters:**
- `bundle`: "true" for bundle-bugs only, "false" to exclude bundle-bugs (default: "false")

**Examples:**
```bash
# Exclude bundle bugs (default)
just query-bugs acm 2.15.1

# Query bundle bugs only
just query-bugs acm 2.15.1 true
```

#### `query-cves`
Query CVEs from Jira for a specific version.

```bash
just query-cves <app> <version>
```

**Example:**
```bash
just query-cves mce 2.10.1
```

**Note:** Exits with code 1 if any FIXME entries exist (missing component mappings).

### Generate Recipes

Generate release YAMLs (output to stdout).

```bash
just generate-payload <type> <app> <version> <snapshot> [rc]
just generate-catalog <type> <app> <version> <snapshot> [rc]
just generate-bundle <type> <app> <version> <snapshot> [rc]
```

**Example:**
```bash
just generate-payload prod acm 2.15.1 snapshot-xyz > payload.yaml
```

### Apply Recipes

Generate and apply release YAMLs directly to the cluster.

```bash
just apply-payload <type> <app> <version> <snapshot> [rc] [skip_confirm] [dry_run]
just apply-catalog <type> <app> <version> <snapshot> [rc] [skip_confirm] [dry_run]
just apply-bundle <type> <app> <version> <snapshot> [rc] [skip_confirm] [dry_run]
```

**Example:**
```bash
just apply-payload prod acm 2.15.1 snapshot-xyz "" false false
```

## Configuration

### Variables

Set these at the command line or in your environment:

#### `debug`
Enable debug output (default: "false")

```bash
just debug=true release payload prod acm 2.15.1 snapshot-xyz
```

#### `workspace`
Base directory for saving release files (default: ".")

```bash
just workspace=/path/to/releases release payload prod acm 2.15.1 snapshot-xyz
```

## Directory Structure

Release files are saved following this structure:

**Production:**
```
workspace/
  ACM/
    ACM-2.15.1/
      snapshot-acm-215-payload-prod-z1.yaml
      acm-215-payload-prod-z1.yaml
      acm-215-catalog-prod-z1.yaml
      acm-215-bundle-prod-z1.yaml
```

**Stage:**
```
workspace/
  MCE/
    MCE-2.10.1/
      rc1/
        snapshot-mce-210-payload-stage-z1-rc1.yaml
        mce-210-payload-stage-z1-rc1.yaml
        mce-210-catalog-stage-z1-rc1.yaml
        mce-210-bundle-stage-z1-rc1.yaml
```

## Common Workflows

### Creating a Stage Release

1. Find the snapshot name from Konflux
2. Run the release recipe with stage type:
   ```bash
   just release payload stage acm 2.15.1 snapshot-release-acm-215-abc123 1
   ```
3. Review the generated YAML
4. Press Enter to apply (dry-run)
5. If satisfied, re-run with `dry_run=false`

### Creating a Production Release

1. Ensure all RCs are complete and approved
2. Find the final snapshot name
3. Run the release recipe:
   ```bash
   just release payload prod acm 2.15.1 snapshot-release-acm-215-xyz789
   ```
4. Review carefully
5. Apply live with:
   ```bash
   just release payload prod acm 2.15.1 snapshot-release-acm-215-xyz789 "" skip_confirm=true dry_run=false
   ```

### Querying Release Contents

```bash
# Check what bugs will be included
just query-bugs acm 2.15.1 false

# Check what CVEs will be included
just query-cves acm 2.15.1

# Generate payload to preview
just generate-payload prod acm 2.15.1 snapshot-xyz
```

## Troubleshooting

### "Failed to get git user.email"

Configure your git identity:
```bash
git config user.name "Your Name"
git config user.email "your.email@redhat.com"
```

### "Failed to fetch snapshot from cluster"

Ensure you're logged into the Konflux cluster and the snapshot exists:
```bash
oc get snapshot <snapshot-name> -n crt-redhat-acm-tenant
```

### "FIXME:" entries in CVE output

This means a component is missing from the component registry. The CVE query will exit with code 1 to prevent accidental use. You need to add the missing component mapping before proceeding.

### Jira query returns no results

- Verify the version format matches Jira (e.g., "acm 2.15.1", not "ACM 2.15.1")
- Check that issues exist in Jira with the correct fixVersion
- For bugs, ensure they have doc labels or SFDC cases attached

## Notes

- **Y-stream releases** (X.Y.0) skip bug/CVE queries as they don't include fixes
- **Z-stream releases** (X.Y.Z where Z > 0) include bugs and CVEs
- **Bundle releases** use `bundle=true` flag to query bundle-specific bugs
- All apply operations default to **dry-run** for safety
- Use `skip_confirm=true` carefully - it bypasses the confirmation prompt
