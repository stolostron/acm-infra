#!/usr/bin/env bash

# ==============================================================================
# RELEASE PIPELINE SCANNING
# ==============================================================================

# Function to check release pipeline status for an application
# Outputs CSV to $RELEASE_CSV if set, otherwise data/$application-release-status.csv
check_releases() {
    local app="$1"
    local release_file="${RELEASE_CSV:-data/$app-release-status.csv}"

    echo "release_name,app,status,ec_result,timestamp,pipeline_url" > "$release_file"

    echo "Checking release pipeline status for application: release-$app"

    # Query Konflux for Release resources for this application
    local releases_json
    releases_json=$(oc get releases -l "appstudio.openshift.io/application=release-$app" -o json 2>/dev/null || echo '{"items":[]}')

    if [[ -z "$releases_json" ]] || [[ "$releases_json" == "null" ]]; then
        echo "No Release resources found for release-$app"
        return 0
    fi

    local release_count
    release_count=$(echo "$releases_json" | jq '.items | length' 2>/dev/null)

    if [[ -z "$release_count" ]] || [[ "$release_count" == "0" ]]; then
        echo "No Release resources found for release-$app"
        return 0
    fi

    echo "Found $release_count releases for release-$app"

    # Process each release (most recent 10 to keep output manageable)
    while read -r release; do
        local release_name
        release_name=$(echo "$release" | jq -r '.metadata.name // "unknown"')

        # Determine overall release status
        local release_status="Unknown"
        local released_condition
        released_condition=$(echo "$release" | jq -r '.status.conditions[] | select(.type == "Released") | .status' 2>/dev/null || echo "")

        if [[ "$released_condition" == "True" ]]; then
            release_status="Succeeded"
        elif [[ "$released_condition" == "False" ]]; then
            release_status="Failed"
        else
            # Check if still in progress
            local processing_condition
            processing_condition=$(echo "$release" | jq -r '.status.conditions[] | select(.type == "Processing") | .status' 2>/dev/null || echo "")
            if [[ "$processing_condition" == "True" ]]; then
                release_status="InProgress"
            fi
        fi

        # Extract EC (Enterprise Contract) result from release conditions
        local ec_result="Unknown"
        local validated_condition
        validated_condition=$(echo "$release" | jq -r '.status.conditions[] | select(.type == "Validated") | .status' 2>/dev/null || echo "")
        if [[ "$validated_condition" == "True" ]]; then
            ec_result="Passed"
        elif [[ "$validated_condition" == "False" ]]; then
            ec_result="Failed"
        fi

        # Extract timestamp
        local timestamp
        timestamp=$(echo "$release" | jq -r '.metadata.creationTimestamp // "unknown"')

        # Extract pipeline run URL if available
        local pipeline_url=""
        local pipeline_run
        pipeline_run=$(echo "$release" | jq -r '.status.processing.pipelineRun // empty' 2>/dev/null || echo "")
        if [[ -n "$pipeline_run" ]]; then
            pipeline_url="https://konflux-ui.apps.stone-prd-rh01.pg1f.p1.openshiftapps.com/ns/crt-redhat-acm-tenant/pipelinerun/$pipeline_run"
        fi

        echo "  Release $release_name: $release_status (EC: $ec_result)"

        echo "$release_name,$app,$release_status,$ec_result,$timestamp,$pipeline_url" >> "$release_file"
    done < <(echo "$releases_json" | jq -c '.items | sort_by(.metadata.creationTimestamp) | reverse | .[:10] | .[]' 2>/dev/null)

    echo ""
}
