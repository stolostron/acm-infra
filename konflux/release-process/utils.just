# Private: validate app parameter
_validate_app app:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ "{{app}}" != "acm" && "{{app}}" != "mce" ]]; then
        echo "Error: app must be 'acm' or 'mce'" >&2
        exit 1
    fi

# Private: validate common inputs
_validate type app rc:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ "{{type}}" != "stage" && "{{type}}" != "prod" ]]; then
        echo "Error: type must be 'stage' or 'prod'" >&2
        exit 1
    fi
    if [[ "{{app}}" != "acm" && "{{app}}" != "mce" ]]; then
        echo "Error: app must be 'acm' or 'mce'" >&2
        exit 1
    fi
    if [[ "{{type}}" == "stage" && -z "{{rc}}" ]]; then
        echo "Error: rc parameter is required for stage releases" >&2
        exit 1
    fi

# Private: parse version into major.minor.patch.short_version (space-separated)
_parse_version version:
    #!/usr/bin/env bash
    set -euo pipefail
    major=$(echo "{{version}}" | cut -d. -f1)
    minor=$(echo "{{version}}" | cut -d. -f2)
    patch=$(echo "{{version}}" | cut -d. -f3)
    short_version="${major}${minor}"
    echo "$major $minor $patch $short_version"

# Private: get git author from email
_get_author:
    #!/usr/bin/env bash
    set -euo pipefail
    author=$(git config user.email 2>/dev/null | cut -d'@' -f1)
    if [ -z "$author" ]; then
        echo "❌ Failed to get git user.email. Please configure git:" >&2
        echo "   git config user.email \"your.email@example.com\"" >&2
        exit 1
    fi
    echo "$author"

# Private: build catalog directory paths (returns: release_dir snapshots_dir releases_dir)
_catalog_dirs app version rc:
    #!/usr/bin/env bash
    set -euo pipefail
    base_dir="{{justfile_directory()}}/acm-release-management"
    app_upper=$(echo "{{app}}" | tr '[:lower:]' '[:upper:]')
    release_dir="${base_dir}/${app_upper}/${app_upper}-{{version}}/rc{{rc}}/catalogs"
    snapshots_dir="${release_dir}/snapshots"
    releases_dir="${release_dir}/releases"
    echo "$release_dir $snapshots_dir $releases_dir"

# Private: parse OCP versions string into space-separated list
_parse_ocp_versions ocp_versions:
    #!/usr/bin/env bash
    set -euo pipefail

    versions=()
    IFS=',' read -ra items <<< "{{ocp_versions}}"
    for item in "${items[@]}"; do
        if [[ "$item" =~ ^([0-9]+)\.([0-9]+)-([0-9]+)\.([0-9]+)$ ]]; then
            # Range format: 4.14-4.17
            start_major="${BASH_REMATCH[1]}"
            start_minor="${BASH_REMATCH[2]}"
            end_major="${BASH_REMATCH[3]}"
            end_minor="${BASH_REMATCH[4]}"

            if [[ "$start_major" != "$end_major" ]]; then
                echo "Error: range must have same major version: $item" >&2
                exit 1
            fi

            for ((i=start_minor; i<=end_minor; i++)); do
                versions+=("${start_major}.${i}")
            done
        elif [[ "$item" =~ ^[0-9]+\.[0-9]+$ ]]; then
            # Single version: 4.12
            versions+=("$item")
        else
            echo "Error: invalid OCP version format: $item" >&2
            exit 1
        fi
    done

    # Output versions space-separated
    echo "${versions[@]}"

# Private: show YAML and confirm
_show_and_confirm yaml skip_confirm="false" dry_run="true":
    #!/usr/bin/env bash
    set -euo pipefail

    # Show the YAML to the user
    echo "{{yaml}}"

    # Confirm unless skip_confirm is true
    if [ "{{skip_confirm}}" != "true" ]; then
        echo "" >&2
        if [ "{{dry_run}}" = "true" ]; then
            echo "Press Enter to continue (DRY-RUN), or Ctrl+C to cancel..." >&2
        else
            echo "Press Enter to continue (LIVE), or Ctrl+C to cancel..." >&2
        fi
        read -r
    fi

# Private: apply YAML to cluster with confirmation
_apply yaml skip_confirm="false" dry_run="true":
    #!/usr/bin/env bash
    set -euo pipefail

    # Show and confirm
    just _show_and_confirm "{{yaml}}" {{skip_confirm}} {{dry_run}}

    # Apply to cluster
    if [ "{{dry_run}}" = "true" ]; then
        echo "{{yaml}}" | oc apply --dry-run=server -f -
    else
        echo "{{yaml}}" | oc apply -f -
    fi

# Private: build base release YAML from template
_build_base app snapshot release_name release_plan release_type:
    #!/usr/bin/env bash
    set -euo pipefail

    if [[ "{{debug}}" == "true" ]]; then
        echo "[_build_base] Starting..." >&2
        echo "[_build_base] app={{app}}, snapshot={{snapshot}}" >&2
        echo "[_build_base] release_name={{release_name}}, release_plan={{release_plan}}, release_type={{release_type}}" >&2
    fi

    namespace="crt-redhat-acm-tenant"
    [[ "{{debug}}" == "true" ]] && echo "[_build_base] namespace=$namespace" >&2 || true

    author=$(just _get_author)
    [[ "{{debug}}" == "true" ]] && echo "[_build_base] author=$author" >&2 || true

    [[ "{{debug}}" == "true" ]] && echo "[_build_base] Running yq eval..." >&2 || true

    yq eval ".metadata.name = \"{{release_name}}\" |
        .metadata.namespace = \"$namespace\" |
        .metadata.labels[\"release.appstudio.openshift.io/author\"] = \"$author\" |
        .spec.snapshot = \"{{snapshot}}\" |
        .spec.releasePlan = \"{{release_plan}}\" |
        .spec.data.releaseNotes.type = \"{{release_type}}\"" \
        templates/release.yaml || {
        echo "[_build_base] yq eval failed!" >&2
        exit 1
    }

    [[ "{{debug}}" == "true" ]] && echo "[_build_base] Complete" >&2 || true

# Private: check OpenShift cluster access
_check_oc_cluster:
    #!/usr/bin/env bash
    set -euo pipefail

    expected_cluster="stone-prd-rh01.pg1f.p1.openshiftapps.com"
    expected_project="crt-redhat-acm-tenant"
    console_url="https://console-openshift-console.apps.stone-prd-rh01.pg1f.p1.openshiftapps.com/"

    echo "🔐 Checking OpenShift cluster access..." >&2

    # Check if oc is available
    if ! command -v oc &>/dev/null; then
        echo "❌ oc command not found" >&2
        echo "   Please install the OpenShift CLI" >&2
        exit 1
    fi

    # Check if logged in
    if ! oc whoami &>/dev/null; then
        echo "❌ Not logged into any OpenShift cluster" >&2
        echo "   Please log in at: $console_url" >&2
        exit 1
    fi

    # Check if logged into correct cluster
    current_server=$(oc whoami --show-server)
    if ! echo "$current_server" | grep -q "$expected_cluster"; then
        echo "❌ Logged into wrong cluster: $current_server" >&2
        echo "   Expected cluster: $expected_cluster" >&2
        echo "   Please log in at: $console_url" >&2
        exit 1
    fi

    # Check current project and switch if needed
    current_project=$(oc project -q 2>/dev/null || echo "")
    if [ "$current_project" != "$expected_project" ]; then
        echo "📦 Switching to project $expected_project..." >&2
        if ! oc project "$expected_project" &>/dev/null; then
            echo "❌ Failed to switch to project $expected_project" >&2
            echo "   You may not have access to this project" >&2
            exit 1
        fi
    fi

    echo "✅ OpenShift cluster access verified (project: $expected_project)" >&2

# Private: check GitLab access
_check_gitlab_access:
    #!/usr/bin/env bash
    set -euo pipefail

    gitlab_host="gitlab.cee.redhat.com"
    upstream="acm/acm-release-management"

    echo "🔐 Checking GitLab access..." >&2

    # Test SSH authentication
    if ! ssh -T git@$gitlab_host 2>&1 | grep -q "Welcome to GitLab"; then
        # Try git ls-remote as fallback
        if ! git ls-remote git@$gitlab_host:$upstream.git HEAD &>/dev/null; then
            echo "❌ Cannot access GitLab at $gitlab_host" >&2
            echo "   Please check:" >&2
            echo "   - VPN connection to Red Hat network" >&2
            echo "   - SSH key configured for $gitlab_host" >&2
            exit 1
        fi
    fi

    echo "✅ GitLab access verified" >&2
