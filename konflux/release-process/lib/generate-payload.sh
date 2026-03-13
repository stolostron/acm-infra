#!/usr/bin/env bash
set -euo pipefail

# Usage: generate-payload.sh <type> <app> <version> <snapshot> [rc]
# Example: generate-payload.sh stage acm 2.13.5 release-acm-213-abc123 2

if [ $# -lt 4 ]; then
    echo "Usage: $0 <type> <app> <version> <snapshot> [rc]" >&2
    echo "" >&2
    echo "Arguments:" >&2
    echo "  type      'stage' or 'prod'" >&2
    echo "  app       'acm' or 'mce'" >&2
    echo "  version   Version string (e.g., 2.13.5)" >&2
    echo "  snapshot  Snapshot name" >&2
    echo "  rc        RC number (required for stage)" >&2
    exit 1
fi

type="$1"
app="$2"
version="$3"
snapshot="$4"
rc="${5:-}"

# Validate type
if [[ "$type" != "stage" && "$type" != "prod" ]]; then
    echo "Error: type must be 'stage' or 'prod'" >&2
    exit 1
fi

# Validate app
if [[ "$app" != "acm" && "$app" != "mce" ]]; then
    echo "Error: app must be 'acm' or 'mce'" >&2
    exit 1
fi

# Validate rc for stage
if [[ "$type" == "stage" && -z "$rc" ]]; then
    echo "Error: rc parameter is required for stage releases" >&2
    exit 1
fi

# Parse version
major=$(echo "$version" | cut -d. -f1)
minor=$(echo "$version" | cut -d. -f2)
patch=$(echo "$version" | cut -d. -f3)
short_version="${major}${minor}"

# Set namespace
namespace="crt-redhat-${app}-tenant"

# Get author from git config
author=$(git config user.name || echo "unknown")

# Build metadata
if [ "$type" = "stage" ]; then
    release_name="stage-publish-${app}-${short_version}-z${patch}-rc${rc}-1"
    release_plan="stage-publish-${app}-${short_version}"
else
    release_name="prod-publish-${app}-${short_version}-z${patch}-1"
    release_plan="prod-publish-${app}-${short_version}"
fi

echo "Querying Jira for bugs and CVEs..." >&2

# Query bugs and CVEs (capture as temp files to avoid shell issues)
bugs_file=$(mktemp)
cves_file=$(mktemp)
trap "rm -f $bugs_file $cves_file" EXIT

# Get the directory where this script is located
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(dirname "$script_dir")"

# Run the justfile recipes
cd "$repo_root"
just query-bugs "$app" "$version" > "$bugs_file"
just query-cves "$app" "$version" > "$cves_file"

# Determine release type based on CVEs
cve_count=$(yq 'length' "$cves_file")
bug_count=$(yq 'length' "$bugs_file")

if [ "$cve_count" -gt 0 ]; then
    release_type="RHSA"
elif [ "$bug_count" -gt 0 ]; then
    release_type="RHBA"
else
    release_type="RHEA"
fi

echo "Generating payload YAML..." >&2
echo "  Release type: $release_type" >&2
echo "  Bugs: $bug_count" >&2
echo "  CVEs: $cve_count" >&2

# Start with template and inject values
output=$(yq eval ".metadata.name = \"$release_name\" |
    .metadata.namespace = \"$namespace\" |
    .metadata.labels[\"release.appstudio.openshift.io/author\"] = \"$author\" |
    .spec.snapshot = \"$snapshot\" |
    .spec.releasePlan = \"$release_plan\" |
    .spec.data.releaseNotes.type = \"$release_type\"" \
    templates/payload-stage.yaml)

# Add references for ACM RHSA
if [[ "$app" == "acm" && "$release_type" == "RHSA" ]]; then
    output=$(echo "$output" | yq eval '.spec.data.releaseNotes.references = ["https://access.redhat.com/security/updates/classification/#important"]')
fi

# Add bugs if any
if [ "$bug_count" -gt 0 ]; then
    # Convert bug list to issues format
    bugs_formatted=$(yq eval '[.[] | {"id": ., "source": "issues.redhat.com"}]' "$bugs_file")
    output=$(echo "$output" | yq eval ".spec.data.releaseNotes.issues.fixed = $bugs_formatted")
fi

# Add CVEs if any
if [ "$cve_count" -gt 0 ]; then
    output=$(echo "$output" | yq eval ".spec.data.releaseNotes.cves = load(\"$cves_file\")")
fi

# Output to stdout
echo "$output"
