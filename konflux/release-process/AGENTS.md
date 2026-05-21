## Project Context
- justfile and utils.just are the main code body of this repo
- run `just help` to view the usage of this justfile
- This is ACM/MCE Release Process automation for creating Konflux releases

## Prerequisites
- `oc` CLI logged into Konflux cluster (stone-prd-rh01.pg1f.p1.openshiftapps.com, project: crt-redhat-acm-tenant)
- `gh` CLI configured with GitHub access
- `jira` CLI configured with Red Hat Jira access
- `yq` (mikefarah version) and `jq` installed
- Git user.name and user.email configured
- VPN connection to Red Hat network (for GitLab access)

## Stage Release Workflow

Complete workflow to release to STAGE:

```bash
# 1. Create payload release
just release payload stage acm 2.12.42 --snapshot snapshot-xyz --rc 1 --dry_run false

# 2. Monitor payload release
just check-release <PAYLOAD_RELEASE_NAME>

# 3. Update bundle snapshot (creates PR to operator bundle repo, rc required for stage)
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

# 8. Update catalog request (creates PR to catalog repo, rc required for stage)
just generate-snapshot catalog stage acm 2.12.42 --rc 1 --dry_run false

# 9. Monitor catalog PR merge and wait for pipeline builds
just check-pr catalog <PR_NUMBER>
just check-commit <MERGE_COMMIT_SHA>

# 10. Create catalog release (OCP versions auto-detected)
just release catalog stage acm 2.12.42 --snapshot <CATALOG_SNAPSHOT> --rc 1 --dry_run false

# 11. Monitor catalog releases (OCP versions auto-detected)
just check-catalog-releases stage acm 2.12.42 --rc 1

# 12. Create GitLab MR for release files
just create-mr acm 2.12.42
```

## Prod Release Workflow

Complete workflow to promote STAGE to PROD:

**Important**: `--rc` specifies which stage RC to promote FROM (e.g. `--rc 1` promotes from stage rc1)

```bash
# 1. Promote payload to prod (from stage rc1)
just release payload prod acm 2.12.42 --rc 1 --dry_run false

# 2. Monitor payload release
just check-release <PAYLOAD_RELEASE_NAME>

# 3. Promote bundle to prod (from stage rc1)
just release bundle prod acm 2.12.42 --rc 1 --dry_run false

# 4. Monitor bundle release
just check-release <BUNDLE_RELEASE_NAME>

# 5. Update catalog request for prod (creates PR to catalog repo, rc not needed for prod)
just generate-snapshot catalog prod acm 2.12.42 --dry_run false

# 6. Monitor catalog PR merge and wait for pipeline builds
just check-pr catalog <PR_NUMBER>
just check-commit <MERGE_COMMIT_SHA>

# ⚠️  MANDATORY PAUSE: Send the catalog snapshot to QE in the release thread and
#    WAIT for QE testing to complete before continuing! Do NOT proceed until QE signs off.
# Get the catalog snapshot from the merged PR commit:
just get-catalog-snapshot prod acm <MERGE_COMMIT_SHA>

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

## Key Command Syntax

Main release command:
```bash
just release <target> <type> <app> <version> [--snapshot <name>] [--rc <N>] [--dry_run false]
```

- **target**: payload, bundle, or catalog
- **type**: stage or prod
- **app**: acm or mce
- **version**: e.g., "2.12.42"
- **--snapshot**: Snapshot name (required for stage)
- **--rc**: RC number (required for all; specifies source RC for prod promotions)
- **--dry_run false**: Apply live (default is dry-run)

Generate snapshot/PR:
```bash
just generate-snapshot <target> <type> <app> <version> [--rc <N>] [--dry_run false]
```
- **target**: bundle (updates operator bundle repo) or catalog (updates catalog request)
- **--rc**: Required for stage, not used for prod

Monitoring:
```bash
just check-release <release-name>
just check-catalog-releases <type> <app> <version> [--rc <N>] [ocp_versions]
just check-commit <commit-sha> [app_name] [namespace]
just check-pr <target> <pr-number>   # targets: bundle-acm, bundle-mce, catalog
```

Utilities:
```bash
just retrieve-fbc-catalog-images <app> <version> --rc <N> [--ocp_versions <versions>]
just get-snapshot-from-pr <app> <pr-number>
just verify-catalog-snapshot <type> <app> <version> <snapshot>
just get-catalog-snapshot <type> <app> <commit-sha>
just get-advisory <release-name>
just create-mr <app> <version>
just clone-release-mgmt <branch-name>
just cleanup
```

## Branch Model

All recipes for a given app+version share a single GitLab branch: `release-{app}-{version}` (e.g., `release-acm-2.12.42`). Stage RCs, prod promotions — everything goes on the same branch.

Files are committed and pushed incrementally after each `stage-release` and `prod-release` step, so progress is backed up to GitLab piecewise. At the end of the workflow, `create-mr` opens a GitLab MR to merge the branch into main.

## Multi-App Ordering (ACM + MCE)

When releasing both ACM and MCE together:
- **Payload and bundle steps** may be run concurrently for ACM and MCE (no dependency between them).
- **Catalog step**: MCE catalog must be fully built and released **before** starting the ACM catalog. This applies to all catalog sub-steps (`generate-snapshot catalog`, PR merge, `release catalog`). Complete the entire MCE catalog flow first, then proceed with ACM.

## Common "Gotchas"
- This justfile is using `just 1.46.0`, which has new ways of handeling recipe arguments. No longer do you specify arguments with arg=value, you must instead add the [arg()] descriptor and then pass the argument with `--arg value`. Global variables are still specified with `arg=value` *before* the recipe call (example: `just debug=true <recipe> --<arg> <value>`)
- **All apply operations default to dry-run** - Must pass `--dry_run false` to apply live
- For **catalog** releases, OCP versions are auto-detected from catalog config
- **Y-stream releases** (X.Y.0) skip bug/CVE queries and use RHEA type
- **Z-stream releases** (X.Y.Z where Z > 0) query bugs/CVEs and use RHSA/RHBA/RHEA based on content
- `release payload` must run before `generate-snapshot bundle`
- `release bundle` must run before `generate-snapshot catalog`
- Catalog OCP versions can be manually overridden with `--ocp_versions "4.14,4.15"` or `--ocp_versions "4.14-4.17"`

## Directory Structure

Files saved to acm-release-management repo:
- **Prod**: `ACM/ACM-2.12.42/` (no rc subdirs)
- **Stage**: `ACM/ACM-2.12.42/rc1/` (rc subdirs)
- **Catalogs**: `ACM/ACM-2.12.42/rc1/catalogs/snapshots/` and `.../releases/`

## Release and PR Check Processes

**WARNING: These processes are WIP and may not work reliably.**

These processes can run for extended periods (sometimes over an hour). If a process runs longer than 20 minutes, something likely went wrong and requires manual inspection.

**Important:** When running these tasks, always include a 20 minute timeout to prevent hanging indefinitely.

**Important:** Monitoring commands (`check-release`, `check-catalog-releases`, `check-commit`, `check-pr`) are long-running. Always run them asynchronously or in the background so the user can view progress and cancel if needed. Do not block the session on these commands.

Track release progress:
```bash
just check-release <RELEASE_NAME>
```

Available after `release payload` and `release bundle` commands (not for catalog releases). Use `check-catalog-releases` for catalog monitoring instead.