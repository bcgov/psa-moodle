#!/usr/bin/env python3
"""Collect read-only, credential-free namespace capacity snapshots using oc.

No secrets, environment variables, pod logs, or application data are exported.
This collects current allocation and a metrics snapshot, NOT usage history.
"""

import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import time


def run_oc(arguments):
    result = subprocess.run(
        ["oc", *arguments, "--request-timeout=15s"],
        capture_output=True,
        text=True,
        timeout=25,
        check=False,
    )
    if result.returncode:
        # Do not persist arbitrary server responses or authentication diagnostics.
        if "Forbidden" in result.stderr:
            reason = "Forbidden: current account cannot read this resource"
        elif "Unauthorized" in result.stderr or "logged in" in result.stderr:
            reason = "Unauthorized: renew oc login"
        else:
            reason = "oc failed; check connectivity and access separately"
        raise RuntimeError(reason)
    return result.stdout


def identity(item):
    metadata = item.get("metadata", {})
    return {
        "name": metadata.get("name"),
        "created": metadata.get("creationTimestamp"),
        "owners": [
            {key: owner[key] for key in ("kind", "name") if key in owner}
            for owner in metadata.get("ownerReferences", [])
        ],
    }


def select(item, keys):
    return {key: item[key] for key in keys if key in item}


def project(kind, item):
    """Allowlist fields; never write a full pod or workload manifest."""
    result = identity(item)
    spec = item.get("spec", {})
    status = item.get("status", {})
    if kind == "quotas":
        result["spec"] = select(spec, ("scopes", "scopeSelector", "hard"))
        result["status"] = select(status, ("hard", "used"))
    elif kind == "limits":
        result["limits"] = spec.get("limits", [])
    elif kind == "pods":
        result.update(select(spec, ("activeDeadlineSeconds", "overhead")))
        result["phase"] = status.get("phase")
        result["containers"] = []
        for field in ("containers", "initContainers"):
            for container in spec.get(field, []):
                result["containers"].append({
                    "kind": field,
                    **select(container, ("name", "resources", "restartPolicy")),
                    "mounts": [
                        select(mount, ("name", "mountPath", "readOnly"))
                        for mount in container.get("volumeMounts", [])
                    ],
                })
        result["volumes"] = [
            {"name": volume["name"], "claim": volume["persistentVolumeClaim"]["claimName"]}
            for volume in spec.get("volumes", [])
            if "persistentVolumeClaim" in volume
        ]
        result["container_status"] = [
            select(container, ("name", "ready", "restartCount"))
            for container in status.get("containerStatuses", [])
        ]
    elif kind == "pvcs":
        result["spec"] = select(spec, ("storageClassName", "accessModes", "resources"))
        result["status"] = select(status, ("phase", "capacity"))
    elif kind in ("deployments", "statefulsets"):
        result["replicas"] = spec.get("replicas", 1)
        result["status"] = select(status, ("replicas", "readyReplicas", "availableReplicas"))
    elif kind == "hpas":
        result["spec"] = select(spec, ("scaleTargetRef", "minReplicas", "maxReplicas"))
        result["status"] = select(status, ("currentReplicas", "desiredReplicas"))
    elif kind == "metrics":
        result.update(select(item, ("timestamp", "window")))
        result["containers"] = [
            select(container, ("name", "usage")) for container in item.get("containers", [])
        ]
    return result


def report(bundle):
    lines = [
        f"# Quota evidence snapshot: {bundle['namespace']}",
        "",
        f"Collection started (UTC): {bundle['started_at']}",
        f"Collection finished (UTC): {bundle['finished_at']}",
        "",
        "This is a sequential snapshot, not an atomic inventory or historical average. "
        "Quota `used` means allocated requests. Metrics API CPU covers its reported "
        "window; memory is a working-set sample. Neither is a historical peak.",
        "",
        "## Quotas",
        "",
        "| Quota | Scopes | Resource | Allocated | Hard ceiling |",
        "|---|---|---|---:|---:|",
    ]
    data = bundle["resources"]
    for quota in data.get("quotas", []):
        status = quota.get("status", {})
        scope = ", ".join(quota["spec"].get("scopes", [])) or "Unscoped"
        if quota["spec"].get("scopeSelector"):
            scope += " (see JSON selector)"
        for resource, hard in sorted(status.get("hard", {}).items()):
            used = status.get("used", {}).get(resource, "missing")
            lines.append(f"| {quota['name']} | {scope} | {resource} | {used} | {hard} |")
    lines += [
        "", "## Workloads", "",
        "| Kind | Name | Desired replicas | Ready replicas |",
        "|---|---|---:|---:|",
    ]
    for kind in ("deployments", "statefulsets"):
        for workload in data.get(kind, []):
            lines.append(
                f"| {kind} | {workload['name']} | {workload['replicas']} | "
                f"{workload['status'].get('readyReplicas', 0)} |"
            )
    for hpa in data.get("hpas", []):
        spec = hpa["spec"]
        lines.append(
            f"\nHPA `{hpa['name']}`: {spec.get('minReplicas', 1)}–{spec['maxReplicas']} "
            f"replicas for `{spec['scaleTargetRef']['name']}`."
        )
    metrics = {
        (pod["name"], container["name"]): container.get("usage", {})
        for pod in data.get("metrics", []) for container in pod["containers"]
    }
    lines += [
        "", "## Admitted containers and current usage", "",
        "Regular and init containers are listed separately; do not simply sum both "
        "to calculate pod admission. Quota status is the authoritative allocation. "
        "Missing usage is not zero. Metric timestamps/windows are retained in JSON.",
        "",
        "| Pod | Phase | Container type / name | CPU request | Memory request | "
        "CPU limit | Memory limit | Sample CPU | Sample memory |",
        "|---|---|---|---:|---:|---:|---:|---:|---:|",
    ]
    for pod in data.get("pods", []):
        for container in pod["containers"]:
            resources = container.get("resources", {})
            requested = resources.get("requests", {})
            limits = resources.get("limits", {})
            usage = metrics.get((pod["name"], container["name"]), {})
            lines.append(
                f"| {pod['name']} | {pod['phase']} | {container['kind']} / {container['name']} "
                f"| {requested.get('cpu', 'unset')} | {requested.get('memory', 'unset')} "
                f"| {limits.get('cpu', 'unset')} | {limits.get('memory', 'unset')} "
                f"| {usage.get('cpu', 'unavailable')} | {usage.get('memory', 'unavailable')} |"
            )
    lines += [
        "", "## PVC inventory", "",
        "Mounted-pod references include completed pods. This is allocated capacity, "
        "not filesystem utilization; used bytes need monitoring or a separate filesystem sample.",
        "",
        "| PVC | Class | Requested | Provisioned | Phase | Referencing pods |",
        "|---|---|---:|---:|---|---|",
    ]
    for pvc in data.get("pvcs", []):
        pods = [
            pod["name"] for pod in data.get("pods", [])
            if any(volume["claim"] == pvc["name"] for volume in pod["volumes"])
        ]
        lines.append(
            f"| {pvc['name']} | {pvc['spec'].get('storageClassName', 'unset')} "
            f"| {pvc['spec'].get('resources', {}).get('requests', {}).get('storage', 'unset')} "
            f"| {pvc['status'].get('capacity', {}).get('storage', 'unavailable')} "
            f"| {pvc['status'].get('phase', 'unknown')} | {', '.join(pods) or 'None found'} |"
        )
    if bundle["errors"]:
        lines += ["", "## Collection gaps", ""]
        lines += [f"- {kind}: {error}" for kind, error in bundle["errors"].items()]
    return "\n".join(lines) + "\n"


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("namespaces", nargs="+")
    parser.add_argument("--output", type=Path, required=True, help="New output directory")
    parser.add_argument("--delay", type=float, default=2, help="Seconds between sequential API reads (minimum 2)")
    args = parser.parse_args()
    if args.delay < 2 or not all(re.fullmatch(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?", ns) for ns in args.namespaces):
        parser.error("Use valid namespace names and a delay of at least two seconds")
    # Refuse overwriting earlier evidence. No kubectl context or cluster mutations.
    args.output.mkdir(parents=True, exist_ok=False, mode=0o700)
    context = subprocess.run(
        ["oc", "config", "current-context"], capture_output=True, text=True, check=True
    ).stdout.strip()
    manifest = {"started_at": now(), "files": {}, "errors": {}}
    paths = {
        "quotas": "/api/v1/namespaces/{ns}/resourcequotas",
        "limits": "/api/v1/namespaces/{ns}/limitranges",
        "pods": "/api/v1/namespaces/{ns}/pods",
        "pvcs": "/api/v1/namespaces/{ns}/persistentvolumeclaims",
        "deployments": "/apis/apps/v1/namespaces/{ns}/deployments",
        "statefulsets": "/apis/apps/v1/namespaces/{ns}/statefulsets",
        "hpas": "/apis/autoscaling/v2/namespaces/{ns}/horizontalpodautoscalers",
        "metrics": "/apis/metrics.k8s.io/v1beta1/namespaces/{ns}/pods",
    }
    for namespace in dict.fromkeys(args.namespaces):
        bundle = {
            "namespace": namespace, "context": context, "started_at": now(),
            "resources": {}, "collection_times": {}, "errors": {},
        }
        for kind, template in paths.items():
            print(f"Reading {namespace}: {kind}", flush=True)
            path = template.format(ns=namespace)
            try:
                response = json.loads(run_oc(["--context", context, "get", "--raw", path]))
                bundle["resources"][kind] = [project(kind, item) for item in response["items"]]
            except (RuntimeError, subprocess.TimeoutExpired, json.JSONDecodeError, KeyError) as error:
                bundle["errors"][kind] = str(error) if isinstance(error, RuntimeError) else type(error).__name__
            bundle["collection_times"][kind] = now()
            time.sleep(args.delay)
        bundle["finished_at"] = now()
        for suffix, content in (
            ("json", json.dumps(bundle, indent=2) + "\n"),
            ("md", report(bundle)),
        ):
            filename = f"{namespace}.{suffix}"
            (args.output / filename).write_text(content)
            manifest["files"][filename] = hashlib.sha256(content.encode()).hexdigest()
        if bundle["errors"]:
            manifest["errors"][namespace] = bundle["errors"]
    manifest["finished_at"] = now()
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Saved to {args.output}; collection gaps: {len(manifest['errors'])} namespace(s)")
    return 1 if manifest["errors"] else 0


if __name__ == "__main__":
    sys.exit(main())
