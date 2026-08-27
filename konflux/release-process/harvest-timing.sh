#!/usr/bin/env bash
# Harvest historical release timing data from every stage/prod payload,
# bundle, and catalog Release CR currently in the cluster.
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
# distinct catalog run). Version is parsed from a "-<app>-<NNN>-z<N>"
# segment in the release NAME when present, else recorded as "unknown".
#
# The cluster only retains Release CRs for ~7 days (status.expirationTime =
# creationTimestamp + 7d), so this is a best-effort snapshot of whatever is
# still around, not a full 30-day history. Run it periodically (and commit
# the resulting CSV under timing-data/) to build up longer history over
# time.
#
# Usage:
#   ./harvest-timing.sh            # harvest and write timing-data/<date>.csv
#   ./harvest-timing.sh --dry-run  # print the rows that would be written, without writing
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="crt-redhat-acm-tenant"
OUT_DIR="${SCRIPT_DIR}/timing-data"
DATE_STAMP="$(date -u +%Y%m%d)"
OUT_FILE="${OUT_DIR}/${DATE_STAMP}.csv"
DRY_RUN=false

if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
fi

command -v oc >/dev/null || { echo "Error: oc CLI not found" >&2; exit 1; }
command -v jq >/dev/null || { echo "Error: jq not found" >&2; exit 1; }

mkdir -p "$OUT_DIR"

echo "Fetching releases from namespace ${NAMESPACE}..." >&2
releases_json=$(oc get release -n "$NAMESPACE" -o json)

# Classify every Release CR, derive app/type/version, compute duration from
# the CR's own status.startTime/completionTime, and emit one CSV row per
# release (header added separately below).
rows=$(echo "$releases_json" | jq -r '
  def ver_major_minor(nnn): (nnn[0:1] + "." + nnn[1:]);

  [ .items[]
    | .metadata.name as $name
    | (.metadata.labels."release.appstudio.openshift.io/releasePlan" // "") as $plan
    | ( [(.status.conditions // [])[] | select(.type=="Released") | .status] | .[0] // "False") as $released
    | (.status.startTime // "null") as $start
    | (.status.completionTime // "null") as $completion
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
        | ($name | capture("-(?<app2>acm|mce)-(?<nnn>[0-9]+)-z(?<patch>[0-9]+)"; "") // null) as $v
        | {
            step: "catalog-release",
            type: $c.type,
            app: $c.app,
            version: (if $v then (ver_major_minor($v.nnn) + "." + $v.patch) else "unknown" end),
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

if [[ -z "$rows" ]]; then
    echo "No matching releases found in namespace ${NAMESPACE}." >&2
    exit 1
fi

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

# Iterate one release at a time, grouped by step (all payloads, then all
# bundles, then all catalogs) rather than interleaved, per user preference.
for step in payload-release bundle-release catalog-release; do
    while IFS=$'\t' read -r release type row_step name released start completion; do
        [[ "$row_step" != "$step" ]] && continue
        duration=$(compute_duration "$start" "$completion")
        echo "  [$step] ${release} (${type}) -> ${name} released=${released}" >&2
        printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$release" "$type" "$row_step" "$name" "$released" "$start" "$completion" "$duration" \
            >> "$tmp_file"
    done <<< "$rows"
done

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
