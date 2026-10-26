#!/usr/bin/env python3
"""
scan-rox-cves.py - Scan roxctl-scan CVE reports for a Konflux application's components.

Konflux component builds run a `roxctl-scan` task that scans the built container
image for CVEs (via ACS). The parsed scan report is attached to the image in the
registry as an OCI artifact (artifact type `application/vnd.redhat.rox-report+json`).

This script:
  1. Lists the components of a Konflux application (release-<application>)
  2. For each component, resolves its latest promoted image
  3. Fetches the attached rox report(s) from the registry (anonymous read)
  4. Filters for FIXABLE Critical / Important CVEs (fixedBy is set)
  5. Writes a CSV summary and a JSON details file for JIRA issue creation

Output files (in --output-dir):
  <application>-rox-cves.csv   - one row per component
  <application>-rox-cves.json  - full CVE details per component

Usage:
  scan-rox-cves.py [--output-dir DIR] [--debug] [--timeout SECONDS] <application>

Example:
  scan-rox-cves.py --output-dir data acm-215

Requires: oc (authenticated to the Konflux cluster, crt-redhat-acm-tenant project),
python3 stdlib only.
"""

import argparse
import csv
import json
import subprocess
import sys
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone

REGISTRY = "quay.io"
ROX_ARTIFACT_TYPE = "application/vnd.redhat.rox-report+json"
CSV_HEADER = [
    "Konflux Component", "Image Digest", "Report Time", "Status",
    "Critical Fixable", "Important Fixable", "Critical Unpatched", "Important Unpatched",
    "Fixable C/I CVEs",
]

SEVERITIES = {
    "CRITICAL_VULNERABILITY_SEVERITY": "Critical",
    "IMPORTANT_VULNERABILITY_SEVERITY": "Important",
    "MODERATE_VULNERABILITY_SEVERITY": "Moderate",
    "LOW_VULNERABILITY_SEVERITY": "Low",
}

_token_cache = {}


def debug(msg):
    if ARGS.debug:
        print(f"[debug] {msg}", file=sys.stderr)


def http_json(url, token=None, retries=3, timeout=None):
    """GET a URL and return parsed JSON, with retries."""
    timeout = timeout or ARGS.timeout
    last_err = None
    for attempt in range(retries):
        req = urllib.request.Request(url)
        if token:
            req.add_header("Authorization", f"Bearer {token}")
        req.add_header("Accept", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as e:
            last_err = e
            debug(f"attempt {attempt + 1}/{retries} failed for {url}: {e}")
    raise RuntimeError(f"GET {url} failed after {retries} attempts: {last_err}")


def http_bytes(url, token=None, retries=3, timeout=None):
    """GET a URL following redirects, return bytes."""
    timeout = timeout or ARGS.timeout
    last_err = None
    for attempt in range(retries):
        req = urllib.request.Request(url)
        if token:
            req.add_header("Authorization", f"Bearer {token}")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.read()
        except (urllib.error.URLError, TimeoutError) as e:
            last_err = e
            debug(f"attempt {attempt + 1}/{retries} failed for {url}: {e}")
    raise RuntimeError(f"GET {url} failed after {retries} attempts: {last_err}")


def registry_token(repo):
    """Anonymous pull token for a repository (cached)."""
    if repo in _token_cache:
        return _token_cache[repo]
    url = f"https://{REGISTRY}/v2/auth?scope=repository:{repo}:pull&service={REGISTRY}"
    data = http_json(url)
    token = data.get("token", "")
    if not token:
        raise RuntimeError(f"no anonymous token granted for {repo}")
    _token_cache[repo] = token
    return token


def get_components(application):
    """Return {component_name: image} for the application via oc.

    The image is taken from the component's latest branch-build snapshot
    (push/incoming events; PR-build snapshots are skipped) so that it matches
    the image the roxctl-scan task scanned. Falls back to the component's
    lastPromotedImage when no snapshot is available.
    """
    app_name = f"release-{application}"
    try:
        result = subprocess.run(
            ["oc", "get", "components", "-o", "json"],
            capture_output=True, text=True, timeout=120, check=True,
        )
    except subprocess.CalledProcessError as e:
        print(f"ERROR: oc get components failed: {e.stderr[:300]}", file=sys.stderr)
        sys.exit(1)
    items = json.loads(result.stdout).get("items", [])
    names, promoted = [], {}
    for c in items:
        if c.get("spec", {}).get("application") != app_name:
            continue
        name = c["metadata"]["name"]
        names.append(name)
        promoted[name] = (c.get("status", {}).get("lastPromotedImage")
                          or c.get("spec", {}).get("containerImage") or "")

    # Latest branch-build snapshot per component
    try:
        result = subprocess.run(
            ["oc", "get", "snapshots", "-l",
             f"appstudio.openshift.io/application={app_name}", "-o", "json"],
            capture_output=True, text=True, timeout=300, check=True,
        )
        snaps = json.loads(result.stdout).get("items", [])
    except (subprocess.CalledProcessError, json.JSONDecodeError) as e:
        print(f"WARNING: could not list snapshots ({e}); falling back to "
              f"lastPromotedImage", file=sys.stderr)
        snaps = []

    latest_branch = {}   # component -> (created, image)
    latest_any = {}      # component -> (created, image)
    for s in snaps:
        m = s["metadata"]
        labels = m.get("labels", {})
        comp = labels.get("appstudio.openshift.io/component")
        if not comp:
            continue
        created = m.get("creationTimestamp", "")
        event = labels.get("pac.test.appstudio.openshift.io/event-type", "")
        for entry in s.get("spec", {}).get("components", []):
            if entry.get("name") != comp:
                continue
            image = entry.get("containerImage", "")
            if not image:
                continue
            if (comp not in latest_any or created > latest_any[comp][0]):
                latest_any[comp] = (created, image)
            if event != "pull_request" and (
                    comp not in latest_branch or created > latest_branch[comp][0]):
                latest_branch[comp] = (created, image)

    components = {}
    for name in names:
        if name in latest_branch:
            components[name] = latest_branch[name][1]
        elif name in latest_any:
            components[name] = latest_any[name][1]
        else:
            components[name] = promoted[name]
    return components


def fetch_rox_reports(image):
    """Fetch and merge all rox reports attached to an image.

    Reports are attached per-architecture, so when the image digest refers to a
    multiarch index we resolve its child manifests and query each of them.

    Returns (report_time, cves) where cves is a merged, de-duplicated list.
    """
    # image looks like quay.io/redhat-user-workloads/crt-redhat-acm-tenant/<comp>@sha256:...
    if "@" not in image:
        raise RuntimeError(f"image has no digest: {image}")
    full_repo, digest = image.split("@", 1)
    if not full_repo.startswith(f"{REGISTRY}/"):
        raise RuntimeError(f"unsupported registry in image: {image}")
    repo = full_repo[len(REGISTRY) + 1:]

    token = registry_token(repo)

    # Candidate digests: the image digest itself, plus child manifests if the
    # digest refers to a multiarch index (reports attach per-arch).
    candidates = [digest]
    index = http_json(f"https://{REGISTRY}/v2/{repo}/manifests/{digest}", token=token)
    if isinstance(index.get("manifests"), list) and index["manifests"]:
        candidates.extend(m["digest"] for m in index["manifests"]
                          if m.get("digest"))
    debug(f"{repo}: checking {len(candidates)} digest(s) for rox reports")

    merged = {}
    report_time = ""
    for cand in candidates:
        try:
            referrers = http_json(
                f"https://{REGISTRY}/v2/{repo}/referrers/{cand}", token=token
            )
        except RuntimeError:
            continue  # referrers API may 404 for some digests - not fatal
        rox_refs = [
            m for m in referrers.get("manifests", [])
            if m.get("artifactType") == ROX_ARTIFACT_TYPE
        ]
        for ref in rox_refs:
            created = ref.get("annotations", {}).get(
                "org.opencontainers.image.created", "")
            if created > report_time:
                report_time = created
            manifest = http_json(
                f"https://{REGISTRY}/v2/{repo}/manifests/{ref['digest']}",
                token=token,
            )
            for layer in manifest.get("layers", []):
                blob = http_bytes(
                    f"https://{REGISTRY}/v2/{repo}/blobs/{layer['digest']}",
                    token=token,
                )
                report = json.loads(blob.decode("utf-8"))
                # Reports are keyed by output format (e.g. "roxctl_new");
                # accept either a dict of lists or a bare list.
                lists = (report.values() if isinstance(report, dict)
                         else [report])
                for vulns in lists:
                    if not isinstance(vulns, list):
                        continue
                    for v in vulns:
                        cve_id = v.get("cve", "")
                        if not cve_id:
                            continue
                        entry = merged.setdefault(cve_id, v)
                        if entry is not v:
                            seen = {(c.get("component"), c.get("version"))
                                    for c in entry.get("components", [])}
                            for c in v.get("components", []):
                                if (c.get("component"), c.get("version")) not in seen:
                                    entry.setdefault("components", []).append(c)
    if not merged:
        raise LookupError("no rox report attached to image")
    if not report_time:
        report_time = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return report_time, list(merged.values())


def classify(cves):
    """Split CVEs into fixable/unpatched Critical+Important buckets."""
    out = {
        "critical_fixable": [], "important_fixable": [],
        "critical_unpatched": [], "important_unpatched": [],
    }
    for v in cves:
        sev = v.get("severity", "")
        fixable = bool(v.get("fixedBy"))
        if sev == "CRITICAL_VULNERABILITY_SEVERITY":
            bucket = "critical_fixable" if fixable else "critical_unpatched"
        elif sev == "IMPORTANT_VULNERABILITY_SEVERITY":
            bucket = "important_fixable" if fixable else "important_unpatched"
        else:
            continue
        out[bucket].append(v)
    return out


def scan_component(name, image):
    """Scan one component. Returns its result row (dict)."""
    result = {
        "component": name, "image": image, "digest": "", "status": "ERROR",
        "report_time": "", "error": "",
        "critical_fixable": 0, "important_fixable": 0,
        "critical_unpatched": 0, "important_unpatched": 0,
        "cves": [],
    }
    if not image:
        result["status"] = "NO_IMAGE"
        result["error"] = "component has no promoted image"
        return result
    if "@sha256:" not in image:
        result["status"] = "NO_IMAGE"
        result["error"] = f"image ref has no digest: {image}"
        return result
    result["digest"] = image.split("@", 1)[1]
    try:
        report_time, cves = fetch_rox_reports(image)
    except LookupError:
        result["status"] = "NO_SCAN"
        result["error"] = "no roxctl-scan report attached (build predates scan rollout?)"
        return result
    except Exception as e:  # noqa: BLE001 - report and continue with other components
        result["status"] = "ERROR"
        result["error"] = str(e)[:300]
        return result

    buckets = classify(cves)
    result["report_time"] = report_time
    for key in ("critical_fixable", "important_fixable",
                "critical_unpatched", "important_unpatched"):
        result[key] = len(buckets[key])
    # Keep all Critical/Important CVEs (fixable flagged) for the JIRA details.
    result["cves"] = (
        [{**v, "fixable": bool(v.get("fixedBy"))}
         for v in buckets["critical_fixable"] + buckets["important_fixable"]
         + buckets["critical_unpatched"] + buckets["important_unpatched"]]
    )
    result["status"] = "FLAGGED" if (result["critical_fixable"]
                                     + result["important_fixable"]) > 0 else "OK"
    return result


def main():
    global ARGS
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    parser.add_argument("application", help="application name (e.g. acm-215)")
    parser.add_argument("--output-dir", default="data", help="output directory")
    parser.add_argument("--timeout", type=int, default=30, help="per-request timeout (s)")
    parser.add_argument("--workers", type=int, default=8, help="parallel registry workers")
    parser.add_argument("--debug", action="store_true")
    ARGS = parser.parse_args()

    application = ARGS.application
    print(f"Scanning roxctl-scan CVE reports for {application} "
          f"(application release-{application})")

    components = get_components(application)
    if not components:
        print(f"ERROR: no components found for application release-{application}",
              file=sys.stderr)
        sys.exit(1)
    print(f"Found {len(components)} components")

    results = []
    with ThreadPoolExecutor(max_workers=ARGS.workers) as pool:
        futures = {pool.submit(scan_component, n, i): n for n, i in components.items()}
        for future in as_completed(futures):
            name = futures[future]
            try:
                results.append(future.result())
            except Exception as e:  # noqa: BLE001
                results.append({"component": name, "image": "", "digest": "",
                                "status": "ERROR", "report_time": "", "error": str(e)[:300],
                                "critical_fixable": 0, "important_fixable": 0,
                                "critical_unpatched": 0, "important_unpatched": 0,
                                "cves": []})
    results.sort(key=lambda r: r["component"])

    # Write CSV
    import os
    os.makedirs(ARGS.output_dir, exist_ok=True)
    csv_file = f"{ARGS.output_dir}/{application}-rox-cves.csv"
    with open(csv_file, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(CSV_HEADER)
        for r in results:
            flagged = r["critical_fixable"] + r["important_fixable"]
            cve_ids = ";".join(
                v["cve"] for v in r["cves"] if v.get("fixable"))[:400]
            writer.writerow([
                r["component"], r["digest"], r["report_time"], r["status"],
                r["critical_fixable"], r["important_fixable"],
                r["critical_unpatched"], r["important_unpatched"],
                cve_ids if flagged else "",
            ])

    # Write JSON (full details for JIRA creation)
    json_file = f"{ARGS.output_dir}/{application}-rox-cves.json"
    with open(json_file, "w") as f:
        json.dump({
            "application": application,
            "scan_time": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "components": {r["component"]: r for r in results},
        }, f, indent=1)

    # Summary
    counts = {}
    for r in results:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    flagged = [r for r in results if r["status"] == "FLAGGED"]
    print(f"\nResults: {dict(counts)}")
    print(f"CSV:  {csv_file}")
    print(f"JSON: {json_file}")
    if flagged:
        print(f"\nComponents with FIXABLE Critical/Important CVEs: {len(flagged)}")
        for r in flagged:
            print(f"  {r['component']}: {r['critical_fixable']} critical, "
                  f"{r['important_fixable']} important (fixable)")
    else:
        print("\nNo fixable Critical/Important CVEs found")
    return 0


if __name__ == "__main__":
    sys.exit(main())
