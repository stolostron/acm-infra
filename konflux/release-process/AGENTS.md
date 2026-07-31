# Agent Instructions for Release Process

## Agent Role

Act as a **guide only**. Present commands with correct arguments filled in based on context. Explain what each step does and what comes next. The user runs all commands themselves.

## Guardrails

- **NEVER execute any `just` commands.** Not release commands, not monitoring commands, not cleanup. Guide only.
- **NEVER run commands with `--dry_run false`** — only the user applies live changes.
- **NEVER skip the QE pause** during prod workflow step 8 (see README.md). The user must wait for QE sign-off before proceeding.
- **NEVER start ACM catalog steps before MCE catalog is fully complete** when releasing both apps.
- **NEVER run `generate-snapshot bundle` before `release payload` completes.**
- **NEVER run `generate-snapshot catalog` before `release bundle` completes.**
- When presenting monitoring commands (`check-release`, `check-catalog-releases`, `check-commit`, `check-pr`), always warn the user these are long-running (can exceed 20 minutes) and suggest running them in a separate terminal.

## Project Context

- ACM/MCE Release Process automation for creating Konflux releases
- Language: justfile (just 1.46.0), Python 3, shell
- Run `just help` to view all available recipes

## Key Files

| File | Purpose |
|------|---------|
| `justfile` | Main recipe definitions |
| `utils.just` | Shared utility recipes |
| `lib/split_snapshot.py` | Catalog snapshot splitting logic |
| `templates/release.yaml` | Release YAML template |
| `bundle-repos/` | Cloned bundle/catalog repos (gitignored, created at runtime) |
| `acm-release-management/` | Cloned release management repo (gitignored, created at runtime) |
| `README.md` | Full command syntax, workflow steps, troubleshooting |

## Prerequisites

- `oc` CLI logged into Konflux cluster (stone-prd-rh01.pg1f.p1.openshiftapps.com, project: crt-redhat-acm-tenant)
- `gh` CLI configured with GitHub access
- `jira` CLI configured with Red Hat Jira access
- `yq` (mikefarah version) and `jq` installed
- Git user.name and user.email configured
- VPN connection to Red Hat network (for GitLab access)

## Workflows

See `README.md` for complete step-by-step stage and prod release workflows with full command syntax.

Key ordering constraint: **payload → bundle → catalog** (each step depends on the previous).

When releasing both ACM and MCE:
- Payload and bundle steps can run concurrently for ACM and MCE
- **MCE catalog must fully complete before starting ACM catalog** — this includes all sub-steps (`generate-snapshot catalog`, PR merge, `release catalog`)
- The PR created by `generate-snapshot` auto-merges, so there is no pause point during that step

## RC Selection

The `--rc` value in `generate-snapshot` selects the *source snapshot* from the previous step, not the RC being created:
- `generate-snapshot bundle --rc N` → finds the **payload** snapshot from `release payload` rc N
- `generate-snapshot catalog --rc N` → finds the **bundle** snapshot from `release bundle` rc N

When retrying with a new RC suffix (e.g., `1-3`): if payload was released under `rc1`, `generate-snapshot bundle` still uses `--rc 1`. But `release bundle` and later steps use the new RC.

## Error Recovery

### `check-release` times out (>20 minutes)
1. Have the user inspect the Release CR directly: `oc get release <name> -o yaml`
2. Check `.status.conditions` for failure reasons
3. Common cause: advisory creation failure — check `.status.releasePipelineRun`
4. If truly stuck, the user can delete the Release CR and re-run the `release` command

### PR fails to merge (bundle or catalog)
1. Have the user check PR status on GitHub: `gh pr view <PR_NUMBER> --repo <repo>`
2. Common causes: CI failure, merge conflicts, auto-merge not enabled
3. If CI failed: user should inspect the failing check, fix if needed, re-push
4. If merge conflict: user should close PR and re-run `generate-snapshot` to create a fresh PR

### Snapshot not found
1. Verify the user is logged into correct cluster and namespace: `oc project crt-redhat-acm-tenant`
2. Check snapshot exists: `oc get snapshot <name>`
3. Common cause: pipeline hasn't finished building yet — wait and retry
4. For `get-snapshot-from-pr`: ensure the PR is actually merged (not just approved)

### Catalog snapshot not converging
1. `get-catalog-snapshot` requires all OCP component snapshots to share the same git SHA
2. If components are still building, wait and retry
3. If one component failed, user needs to inspect the pipeline run for that component

## Common Gotchas

- justfile uses `just 1.46.0` — recipe arguments use `--arg value` syntax (not `arg=value`). Global variables still use `arg=value` *before* the recipe name (e.g., `just debug=true <recipe> --arg value`)
- All operations default to dry-run — must pass `--dry_run false` to apply live
- Catalog OCP versions are auto-detected from catalog config
- Y-stream releases (X.Y.0) skip bug/CVE queries and use RHEA type
- Z-stream releases (X.Y.Z, Z > 0) query bugs/CVEs and use RHSA/RHBA/RHEA based on content
- Catalog OCP versions can be overridden with `--ocp_versions "4.14,4.15"` or `--ocp_versions "4.14-4.17"`

## Git Conventions

All commits must include a DCO `Signed-off-by` line. See the parent repository AGENTS.md for format and examples.