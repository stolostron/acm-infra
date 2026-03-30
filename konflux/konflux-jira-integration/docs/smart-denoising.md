# Smart Denoising for Konflux Compliance Scanner

## Problem

The Konflux build platform experiences transient failures — temporary cluster instability, quay timeouts, gateway errors, and GitHub API flakiness. When the compliance scanner detects these failures, it immediately creates JIRA issues that land on developers' plates. Most of these failures resolve on their own after a retrigger, resulting in noisy JIRAs that are auto-closed within a day.

This wastes developer attention and erodes trust in the compliance dashboard.

See [Issue #22](https://github.com/stolostron/acm-infra/issues/22) for the original problem report and discussion.

## Solution

Smart denoising introduces a **two-scan confirmation pattern**. Instead of creating a JIRA on the first failure, the scanner:

1. Retriggers the failed build
2. Records it in a pending state file
3. Waits for the build to complete (configurable, default 60 minutes)
4. Re-checks on the next scan
5. Only creates a JIRA if the failure **persists after retrigger**

If the build passes after retrigger, the component is silently removed from the pending state. No JIRA is ever created. Zero noise.

## How It Works

### State Machine

Each component follows this state machine during scans:

```
                    ┌──────────────────────────────────────────────┐
                    │                                              │
                    v                                              │
              ┌──────────┐     failure      ┌─────────┐           │
    scan ---> │ Healthy  │ ───────────────> │ Pending │           │
              └──────────┘                  └────┬────┘           │
                    ^                            │                │
                    │                    retrigger + record        │
                    │                            │                │
                    │                            v                │
                    │                   ┌────────────────┐        │
                    │                   │   Waiting      │        │
                    │                   │ (< wait time)  │──┐     │
                    │                   └────────────────┘  │     │
                    │                            │      skip on   │
                    │               wait time    │    each scan   │
                    │               elapsed      │    until ready │
                    │                            │         │      │
                    │                            v         │      │
                    │                   ┌────────────────┐ │      │
                    │    now passing    │   Re-check     │<┘      │
                    │<─────────────────│  (ready for    │        │
                    │   (recovered)     │   recheck)     │        │
                    │                   └───────┬────────┘        │
                    │                           │                 │
                    │                    still failing             │
                    │                    + retrigger_count >= 1    │
                    │                           │                 │
                    │                           v                 │
                    │                   ┌────────────────┐        │
                    │                   │  Confirmed     │        │
                    │                   │  Failure       │────────┘
                    │                   └───────┬────────┘  (write to
                    │                           │        compliance CSV
                    │                    retrigger_count   → create JIRA)
                    │                    == 0
                    │                           │
                    │                           v
                    │                   retrigger again,
                    │                   increment count,
                    │                   back to Waiting
                    │                           │
                    └───────────────────────────┘
```

### Timeline Example

```
T=0min    Scan detects failure in component "console-acm"
          → Retrigger build (kubectl annotate)
          → Add to pending state: {retrigger_time: T0, retrigger_count: 0}
          → Do NOT create JIRA

T=60min   Next scan runs, "console-acm" is in pending state
          → 60 min >= 60 min wait → ready for recheck
          → retrigger_count is 0 → retrigger again, increment to 1
          → Still waiting

T=120min  Next scan runs, "console-acm" still in pending state
          → 60 min >= 60 min wait → ready for recheck
          → retrigger_count is 1 → check current status:

          Scenario A: Build now passes
          → Remove from pending
          → No JIRA created (false alarm filtered)

          Scenario B: Build still fails
          → Confirmed failure
          → Write to compliance CSV
          → JIRA will be created by create-compliance-jira-issues.sh
```

### Comparison: Before vs After

**Before (without denoising):**

| Time | Event | JIRA |
|------|-------|------|
| T=0 | Scanner detects failure | JIRA created immediately |
| T=24h | Retrigger workflow runs, build passes | JIRA auto-closed |
| Result | Developer was notified, investigated, wasted time | Noise |

**After (with denoising):**

| Time | Event | JIRA |
|------|-------|------|
| T=0 | Scanner detects failure | Retrigger + pending state. No JIRA. |
| T=60min | Scanner re-checks, build passed after retrigger | Removed from pending. No JIRA. |
| Result | Developer never bothered | Zero noise |

## Tiered Scanning

To balance responsiveness with API usage, the scanner operates in two modes:

| Mode | Schedule | Dimensions Checked | GitHub API calls/component |
|------|----------|--------------------|---------------------------|
| **Fast** | Every hour | Push, EC, Promotion | ~2-3 |
| **Full** | Sunday 8AM EST | Push, EC, Promotion, Hermetic, Multiarch | ~5 |

Fast mode skips `.tekton` YAML fetches (hermetic and multiarch checks) since those configurations rarely change. The CSV output shows "Skipped (Fast Scan)" for those columns in fast mode.

### API Budget

With 134 components across 14 applications:

| | Fast (hourly) | Full (weekly) |
|---|---|---|
| GitHub REST API calls | ~392/scan | ~660/scan |
| Scans per hour | 1 | N/A |
| GitHub API limit | 5,000/hour | 5,000/hour |
| Headroom | ~4,600 remaining | ~4,340 remaining |

## Configuration

### Workflow Inputs

When triggering the scanner manually via GitHub Actions, these inputs control denoising:

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `scan_mode` | choice | `fast` | `fast` (Push/EC/Promotion only) or `full` (all 5 dimensions) |
| `enable_denoising` | boolean | `false` | Enable smart denoising for this run. Automatically enabled for scheduled runs. |
| `retrigger_wait_minutes` | string | `60` | Minutes to wait after retrigger before re-checking the component |
| `retrigger_failed` | boolean | `false` | Retrigger failed builds (required for denoising to take action) |
| `create_jira_issues` | boolean | `true` | Create JIRA issues for confirmed failures |

### Environment Variables

These can be set in the workflow YAML or passed to `compliance.sh` directly:

| Variable | Default | Description |
|----------|---------|-------------|
| `RETRIGGER_WAIT_MINUTES` | `60` | Minutes to wait after retrigger before re-checking |
| `PENDING_STALE_HOURS` | `48` | Automatically remove pending entries older than this (safety cleanup) |
| `PENDING_FILE` | `pending-failures.json` | Path to the pending state JSON file |

### compliance.sh Flags

| Flag | Description |
|------|-------------|
| `--scan-mode=fast` | Fast scan: skip hermetic and multiarch checks |
| `--scan-mode=full` | Full scan: check all 5 compliance dimensions |
| `--enable-denoising` | Enable smart denoising (pending state machine) |
| `--retrigger` | Retrigger failed builds via kubectl annotate |

### Scheduled Behavior

| Cron | Mode | Denoising |
|------|------|-----------|
| `0 * * * *` (every hour) | Fast | Enabled |
| `0 13 * * 0` (Sunday 8AM EST) | Full | Enabled |
| Manual trigger | Configurable | Configurable (default: off) |

## Pending State File

### Format

The pending state is stored in `pending-failures.json`, a JSON file managed by `pending-state.sh`:

```json
{
  "console-acm-217": {
    "app": "acm-217",
    "first_seen": "2026-03-30T10:00:00Z",
    "retrigger_time": "2026-03-30T10:00:00Z",
    "retrigger_count": 0,
    "failed_dimensions": "push,ec"
  },
  "search-acm-217": {
    "app": "acm-217",
    "first_seen": "2026-03-30T09:00:00Z",
    "retrigger_time": "2026-03-30T10:00:00Z",
    "retrigger_count": 1,
    "failed_dimensions": "promotion"
  }
}
```

### Fields

| Field | Description |
|-------|-------------|
| `app` | Konflux application name (e.g., `acm-217`) |
| `first_seen` | UTC timestamp when the failure was first detected |
| `retrigger_time` | UTC timestamp of the most recent retrigger |
| `retrigger_count` | How many times the component has been retriggered |
| `failed_dimensions` | Comma-separated list of failing dimensions |

### Persistence

The pending state file is persisted across workflow runs using **GitHub Actions Cache**:

- **Restore**: Before each scan, the cache is restored using a prefix match on `compliance-pending-state-{application}`
- **Save**: After each scan, the cache is saved with key `compliance-pending-state-{application}-{run_id}`
- **Immutability**: GitHub Actions cache keys are immutable. The `run_id` suffix ensures each save creates a new entry. The prefix match on restore picks up the most recent one.
- **Eviction**: GitHub evicts caches not accessed for 7 days. If the cache is lost, the pending state resets — equivalent to a fresh start. No failures are missed; they just go through the full denoising cycle again.

### Stale Entry Cleanup

Entries older than `PENDING_STALE_HOURS` (default: 48 hours) are automatically removed at the start of each scan. This prevents entries from accumulating indefinitely if a component is stuck in a failure loop where the retrigger never completes.

## Interaction with Existing Features

### Compliance Exceptions

Components listed in `compliance-exceptions.yaml` are still honored. Excepted components are marked as `Skipped (Null)` or `Skipped (CEL)` and are not considered failures. They do not enter the pending state.

### Auto-Close

The existing auto-close logic in `create-compliance-jira-issues.sh` continues to work. If a component was a confirmed failure (JIRA was created), and it later passes, the auto-close logic will close the JIRA as before. Denoising reduces the number of JIRAs that need auto-closing by preventing false alarm JIRAs from being created in the first place.

### Skip Duplicates

The `--skip-duplicates` flag still prevents creating duplicate JIRAs for the same component. This is a second layer of protection. With denoising, fewer issues reach the JIRA creation step, so skip-duplicates triggers less frequently.

## Files

| File | Role |
|------|------|
| `scripts/pending-state.sh` | Pending state management library (init, add, remove, recheck timing, cleanup) |
| `scripts/compliance.sh` | Main scanner script. Contains the denoising state machine and tiered scan logic. |
| `scripts/test-pending-state.sh` | Unit tests for pending-state.sh (31 test cases) |
| `.github/workflows/konflux-compliance-scanner.yml` | GitHub Actions workflow with cache, inputs, and cron schedules |

## Testing

### Unit Tests

Run locally (no external dependencies, only `jq` required):

```bash
cd konflux/konflux-jira-integration/scripts
bash test-pending-state.sh
```

This runs 31 test cases covering all `pending-state.sh` functions including timezone handling, stale cleanup, and multi-operation integrity.

### Integration Testing (Manual)

Test in GitHub Actions without creating JIRAs:

1. Go to **Actions** > **Konflux Compliance Scanner** > **Run workflow**
2. Select branch: `smart-denoising-v2` (or `main` after merge)
3. Set inputs:
   - `application`: pick one app (e.g., `mce-211`)
   - `scan_mode`: `fast`
   - `enable_denoising`: `true`
   - `retrigger_failed`: `true`
   - `create_jira_issues`: `false`
   - `retrigger_wait_minutes`: `5` (shortened for testing)
4. Run and check logs for denoising messages:
   - `Smart denoising: enabled` — denoising is active
   - `NEW FAILURE: xxx` — component added to pending
   - `PENDING (waiting): xxx` — component skipped (build still running)
   - `CONFIRMED FAILURE: xxx` — failure persisted after retrigger
   - `RECOVERED: xxx` — component passed after retrigger (no JIRA)
5. Run again after `retrigger_wait_minutes` to see the re-check phase

### Verifying Cache Persistence

After the first run:
1. Go to the repo's **Actions** > **Caches** page
2. Look for `compliance-pending-state-{application}-{run_id}`
3. On the second run, check the "Restore pending state" step log for `Cache restored`

## Troubleshooting

### All components pass but JIRAs are still open

The denoising only prevents *new* JIRAs. Existing JIRAs are closed by the auto-close logic in `create-compliance-jira-issues.sh`, which runs as a separate step after the compliance scan. Make sure `auto_close` is enabled and `create_jira_issues` is `true` for the auto-close to run.

### Pending state seems to reset between runs

Check the "Restore pending state" step in the workflow logs. If it says "Cache not found", the previous cache may have been evicted (GitHub evicts after 7 days of no access) or the application name in the cache key doesn't match. The cache is keyed per application (e.g., `compliance-pending-state-acm-217`).

### Component stays in pending forever

The `PENDING_STALE_HOURS` cleanup (default: 48h) removes entries that have been pending too long. If a component is stuck, it will be cleared after 48 hours and re-enter the denoising cycle on the next failure detection.

### Fast scan misses hermetic/multiarch issues

This is by design. Fast scans only check Push, EC, and Promotion. Hermetic and multiarch are checked during the weekly full scan (Sunday 8AM EST). If you need an immediate full check, trigger a manual run with `scan_mode: full`.
