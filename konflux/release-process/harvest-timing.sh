#!/usr/bin/env bash
# Harvest historical release AND catalog-build timing data since a given
# date, from Release CRs in the cluster plus GitHub check-runs on the
# catalog repo's build branches.
#
# --- Release rows (payload-release, bundle-release, catalog-release) ---
#
# Payload/bundle releases are classified by parsing their Release CR NAME
# (e.g. "stage-publish-acm-217-z1-rc2"): this reliably distinguishes genuine
# manually-triggered releases from the much larger number of Release CRs
# auto-created per commit/snapshot under the same releasePlan (their names
# look like "release-acm-212-20260821-233634-000-...-sn7q2" and never carry
# a "-z<N>" patch segment, so they're naturally excluded).
#
# Catalog releases are classified by their
# `release.appstudio.openshift.io/releasePlan` label instead (e.g.
# "acm-release-plan-prod"), because catalog Release CR *names* have drifted
# across several incompatible conventions over time (retry suffixes like
# "-2", "-rcN", "-multirelease", bare names with no embedded version, etc.)
# and no single name regex catches them all — that's what caused
# "acm-fbc-ocm-4-22-prod-2" to be silently dropped previously. releasePlan
# has no such drift for catalog releases: only genuine catalog releases use
# it (verified empirically — no CI noise), and it reliably identifies type
# (stage/prod) and app (acm/mce) regardless of the name's shape.
#
# Every matching Release CR is recorded individually (no collapsing of
# catalog per-OCP-version siblings into a single "winner" row) so that
# failed/retried attempts remain visible in the output, e.g. a bare
# "acm-fbc-ocm-4-22-prod" (Released=False, retried) alongside the
# "acm-fbc-ocm-4-22-prod-2" that succeeded.
#
# Catalog releasePlan carries no version information at all (it's shared
# across every OCP-version fan-out release for the app+type, across every
# distinct catalog run). Each catalog-release CR is scoped to exactly one
# OCP version (one snapshot component, one "catalogs/ocp-X.Y/Containerfile"),
# and every catalog-release CR name embeds that OCP version as
# "fbc-ocm-<major>-<minor>", so the "release" column for catalog-release
# rows is "<app>-<ocp-major>.<ocp-minor>" (e.g. "acm-4.22") — the OCP
# version, not the ACM/MCE product version. This matches the version scheme
# used for catalog-build rows (see below), so catalog-build and
# catalog-release rows for the same OCP version/type/app line up directly.
# The product version (e.g. 2.16.3), when present in the name at all, stays
# visible in the "reference" column instead (e.g.
# "acm-fbc-ocm-4-22-prod-acm-216-z3").
#
# Release CRs are only retained in-cluster for ~7 days (status.expirationTime
# = creationTimestamp + 7d), so releases older than --since (or than the
# retention window, whichever is later) simply won't be found.
#
# --- Build rows (catalog-build only) ---
#
# Catalog builds have no reliable in-cluster record of *failures*: a failed
# build never produces a Snapshot, and PipelineRuns are garbage-collected
# within hours. The only durable record of both successful and failed
# catalog builds is the GitHub check-run left on the triggering commit in
# stolostron/acm-mce-operator-catalogs, on its "acm-redhat-operators" /
# "mce-redhat-operators" branches (one push per commit fans out a
# "<app>-fbc-ocm-<ocp-major>-<ocp-minor>-<stage|prod>-on-push" check-run per
# OCP version). Every commit on those branches since --since is enumerated
# and each matching check-run becomes one catalog-build row, so failed
# builds are recorded, not just successful ones.
#
# The check-run name only carries the target OCP version (e.g. "4.17"), not
# the ACM/MCE product version — the "release" column for catalog-build rows
# is therefore "<app>-<ocp-major>.<ocp-minor>" (e.g. "acm-4.17"), which is a
# different kind of version than the product versions used in the
# catalog-release rows sourced from the cluster. Disambiguate using the
# "step" column.
#
# Usage:
#   ./harvest-timing.sh                        # harvest since 7 days ago, write timing-data/<date>.csv
#   ./harvest-timing.sh --since 2026-08-24     # harvest since a specific date (controls both releases and builds)
#   ./harvest-timing.sh --dry-run              # print the rows that would be written, without writing
#   ./harvest-timing.sh --since 2026-08-24 --dry-run
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="crt-redhat-acm-tenant"
CATALOG_REPO="stolostron/acm-mce-operator-catalogs"
OUT_DIR="${SCRIPT_DIR}/timing-data"
DATE_STAMP="$(date -u +%Y%m%d)"
OUT_FILE="${OUT_DIR}/${DATE_STAMP}.csv"
DRY_RUN=false
SINCE_DATE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --since)
            SINCE_DATE="${2:-}"
            [[ -z "$SINCE_DATE" ]] && { echo "Error: --since requires a date argument (YYYY-MM-DD)" >&2; exit 1; }
            shift 2
            ;;
        *)
            echo "Error: unknown argument '$1'" >&2
            exit 1
            ;;
    esac
done

[[ -z "$SINCE_DATE" ]] && SINCE_DATE="$(date -u -d '7 days ago' +%Y-%m-%d)"
SINCE_ISO="${SINCE_DATE}T00:00:00Z"
SINCE_EPOCH=$(date -u -d "$SINCE_ISO" +%s 2>/dev/null) || { echo "Error: invalid --since date '$SINCE_DATE'" >&2; exit 1; }

command -v oc >/dev/null || { echo "Error: oc CLI not found" >&2; exit 1; }
command -v jq >/dev/null || { echo "Error: jq not found" >&2; exit 1; }
command -v gh >/dev/null || { echo "Error: gh CLI not found" >&2; exit 1; }

mkdir -p "$OUT_DIR"

echo "Harvesting since ${SINCE_ISO}" >&2

# Compute a human-readable duration (HH:MM:SS) from start/completion
# timestamps. Left as "null" if either is unavailable or unparseable.
compute_duration() {
    local start="$1" stop="$2"
    if [[ "$start" == "null" || "$stop" == "null" ]]; then
        echo "null"
        return
    fi
    local start_epoch end_epoch
    start_epoch=$(date -d "$start" +%s 2>/dev/null || echo "")
    end_epoch=$(date -d "$stop" +%s 2>/dev/null || echo "")
    if [[ -z "$start_epoch" || -z "$end_epoch" ]]; then
        echo "null"
        return
    fi
    local elapsed=$((end_epoch - start_epoch))
    printf '%02d:%02d:%02d' "$((elapsed / 3600))" "$(((elapsed % 3600) / 60))" "$((elapsed % 60))"
}

tmp_file=$(mktemp)
trap 'rm -f "$tmp_file"' EXIT

### --- Release rows (payload-release / bundle-release / catalog-release) ---

echo "Fetching releases from namespace ${NAMESPACE}..." >&2
releases_json=$(oc get release -n "$NAMESPACE" -o json)

# Classify every Release CR, derive app/type/version, compute duration from
# the CR's own status.startTime/completionTime, and emit one row per
# release whose startTime (fallback creationTimestamp) is >= --since.
release_rows=$(echo "$releases_json" | jq -r --arg since "$SINCE_ISO" '
  def ver_major_minor(nnn): (nnn[0:1] + "." + nnn[1:]);

  [ .items[]
    | .metadata.name as $name
    | (.metadata.labels."release.appstudio.openshift.io/releasePlan" // "") as $plan
    | ( [(.status.conditions // [])[] | select(.type=="Released") | .status] | .[0] // "False") as $released
    | (.status.startTime // "null") as $start
    | (.status.completionTime // "null") as $completion
    | ((if $start != "null" then $start else .metadata.creationTimestamp end)) as $effective_start
    | select($effective_start >= $since)
    | if ($name | test("^(stage|prod)-publish-bundle-(acm|mce)-[0-9]+-z[0-9]+")) then
        ($name | capture("^(?<type>stage|prod)-publish-bundle-(?<app>acm|mce)-(?<nnn>[0-9]+)-z(?<patch>[0-9]+)")) as $c
        | {
            step: "bundle-release",
            type: $c.type,
            app: $c.app,
            version: (ver_major_minor($c.nnn) + "." + $c.patch),
            name: $name,
            released: $released,
            start: $start,
            completion: $completion
          }
      elif ($name | test("^(stage|prod)-publish-(acm|mce)-[0-9]+-z[0-9]+")) then
        ($name | capture("^(?<type>stage|prod)-publish-(?<app>acm|mce)-(?<nnn>[0-9]+)-z(?<patch>[0-9]+)")) as $c
        | {
            step: "payload-release",
            type: $c.type,
            app: $c.app,
            version: (ver_major_minor($c.nnn) + "." + $c.patch),
            name: $name,
            released: $released,
            start: $start,
            completion: $completion
          }
      elif ($plan | test("^(acm|mce)-release-plan-(stage|prod)$")) then
        ($plan | capture("^(?<app>acm|mce)-release-plan-(?<type>stage|prod)$")) as $c
        | ($name | capture("fbc-ocm-(?<major>[0-9]+)-(?<minor>[0-9]+)"; "") // null) as $ocp
        | {
            step: "catalog-release",
            type: $c.type,
            app: $c.app,
            version: (if $ocp then ($ocp.major + "." + $ocp.minor) else "unknown" end),
            name: $name,
            released: $released,
            start: $start,
            completion: $completion
          }
      else empty end
  ]
  | .[]
  | . as $r
  | ($r.app + "-" + $r.version) as $release_label
  | [$release_label, $r.type, $r.step, $r.name, $r.released, $r.start, $r.completion] | @tsv
')

if [[ -n "$release_rows" ]]; then
    for step in payload-release bundle-release catalog-release; do
        while IFS=$'\t' read -r release type row_step name released start completion; do
            [[ -z "$row_step" || "$row_step" != "$step" ]] && continue
            duration=$(compute_duration "$start" "$completion")
            echo "  [$step] ${release} (${type}) -> ${name} released=${released}" >&2
            printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
                "$release" "$type" "$row_step" "$name" "$released" "$start" "$completion" "$duration" \
                >> "$tmp_file"
        done <<< "$release_rows"
    done
else
    echo "No matching releases found since ${SINCE_ISO}." >&2
fi

### --- Build rows (catalog-build, from GitHub check-runs) ---

# Catalog builds fan out one "<app>-fbc-ocm-<ocp-major>-<ocp-minor>-<stage|prod>-on-push"
# check-run per OCP version, per commit, on the app's build branch. Every
# commit on that branch since --since is walked and every matching
# check-run (success AND failure) becomes one row.
for app_branch in "acm:acm-redhat-operators" "mce:mce-redhat-operators"; do
    app="${app_branch%%:*}"
    branch="${app_branch##*:}"

    echo "Fetching commits on ${CATALOG_REPO}@${branch} since ${SINCE_ISO}..." >&2
    shas=$(gh api --paginate "repos/${CATALOG_REPO}/commits?sha=${branch}&since=${SINCE_ISO}&per_page=100" 2>/dev/null | jq -r '.[].sha' || true)

    if [[ -z "$shas" ]]; then
        echo "  no commits found on ${branch} since ${SINCE_ISO}" >&2
        continue
    fi

    while read -r sha; do
        [[ -z "$sha" ]] && continue
        checkruns=$(gh api "repos/${CATALOG_REPO}/commits/${sha}/check-runs?per_page=100" 2>/dev/null || true)
        [[ -z "$checkruns" ]] && continue

        while IFS=$'\t' read -r ocp_major ocp_minor type conclusion started completed cr_name; do
            [[ -z "$ocp_major" ]] && continue
            release_label="${app}-${ocp_major}.${ocp_minor}"
            reference="${sha:0:8}/${app}-fbc-ocm-${ocp_major}-${ocp_minor}-${type}"
            released="False"
            [[ "$conclusion" == "success" ]] && released="True"
            start="${started:-null}"
            completion="${completed:-null}"
            [[ -z "$start" || "$start" == "null" ]] && start="null"
            [[ -z "$completion" || "$completion" == "null" ]] && completion="null"
            duration=$(compute_duration "$start" "$completion")
            echo "  [catalog-build] ${release_label} (${type}) -> ${reference} conclusion=${conclusion}" >&2
            printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
                "$release_label" "$type" "catalog-build" "$reference" "$released" "$start" "$completion" "$duration" \
                >> "$tmp_file"
        done < <(echo "$checkruns" | jq -r --arg app "$app" '
            .check_runs[]
            | select(.name | test("^Red Hat Konflux / " + $app + "-fbc-ocm-[0-9]+-[0-9]+-(stage|prod)-on-push$"))
            | (.name | capture($app + "-fbc-ocm-(?<major>[0-9]+)-(?<minor>[0-9]+)-(?<type>stage|prod)-on-push")) as $c
            | [$c.major, $c.minor, $c.type, (.conclusion // "null"), (.started_at // "null"), (.completed_at // "null"), .name]
            | @tsv
        ')
    done <<< "$shas"
done

if [[ ! -s "$tmp_file" ]]; then
    echo "No matching releases or builds found since ${SINCE_ISO}." >&2
    exit 1
fi

if $DRY_RUN; then
    echo "--- planned rows ---"
    echo "release,type,step,reference,released,start_time,stop_time,duration"
    sort -u "$tmp_file"
    exit 0
fi

{
    echo "release,type,step,reference,released,start_time,stop_time,duration"
    sort -u "$tmp_file"
} > "$OUT_FILE"

echo "Wrote $(($(wc -l < "$OUT_FILE") - 1)) rows to ${OUT_FILE}" >&2
