#!/usr/bin/env python3
"""Validate inventory/ports.yaml against itself and against k8s/ manifests.

Fails (exit 1) if:
  1. Two registry entries share the same (port, proto, scope) with status in {live, target}
     (a duplicate claim on the same reachable surface).
  2. A Kubernetes Service of type NodePort or LoadBalancer, or a container `hostPort`, appears
     under k8s/ with a port that has no matching entry in the registry at all (any status).

This intentionally does not require every registry entry to have a live manifest (host-level
ports like sshd/etcd/kubelet/tailscaled have no k8s Service) and does not require every status to
be unique per port (a port legitimately has both a `live`/`remove` row for the current path and a
`target` row for the future one).

Usage: python3 scripts/check-ports.py [--repo-root PATH]
"""
from __future__ import annotations

import argparse
import pathlib
import sys
from collections import defaultdict

try:
    import yaml
except ImportError:
    print("error: PyYAML is required (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)


def load_registry(repo_root: pathlib.Path) -> list[dict]:
    path = repo_root / "inventory" / "ports.yaml"
    if not path.exists():
        print(f"error: {path} not found", file=sys.stderr)
        sys.exit(2)
    with path.open() as f:
        entries = yaml.safe_load(f) or []
    required = {"port", "proto", "scope", "status"}
    for i, e in enumerate(entries):
        missing = required - e.keys()
        if missing:
            print(f"error: {path} entry {i} missing fields: {sorted(missing)}", file=sys.stderr)
            sys.exit(2)
    return entries


def check_duplicates(entries: list[dict]) -> list[str]:
    errors = []
    seen: dict[tuple, list[dict]] = defaultdict(list)
    for e in entries:
        if e["status"] not in ("live", "target"):
            continue
        key = (e["port"], e["proto"], e["scope"])
        seen[key].append(e)
    for key, group in seen.items():
        if len(group) > 1:
            port, proto, scope = key
            services = ", ".join(g.get("service", "?") for g in group)
            errors.append(
                f"duplicate registry entry for port={port} proto={proto} scope={scope} "
                f"(status live/target): {services}"
            )
    return errors


def iter_yaml_docs(repo_root: pathlib.Path):
    k8s_dir = repo_root / "k8s"
    for path in k8s_dir.rglob("*.yaml"):
        try:
            with path.open() as f:
                for doc in yaml.safe_load_all(f):
                    if isinstance(doc, dict):
                        yield path, doc
        except yaml.YAMLError:
            continue


def find_exposed_ports(repo_root: pathlib.Path) -> list[tuple[pathlib.Path, str, int, str]]:
    """Return (file, kind, port, proto) for every NodePort/LoadBalancer Service port and hostPort."""
    found = []
    for path, doc in iter_yaml_docs(repo_root):
        kind = doc.get("kind")
        if kind == "Service":
            spec = doc.get("spec", {}) or {}
            svc_type = spec.get("type")
            if svc_type in ("NodePort", "LoadBalancer"):
                for port_spec in spec.get("ports", []) or []:
                    port = port_spec.get("nodePort") or port_spec.get("port")
                    proto = str(port_spec.get("protocol", "TCP")).lower()
                    if port:
                        found.append((path, f"Service/{svc_type}", int(port), proto))
        if kind in ("Deployment", "StatefulSet", "DaemonSet", "Pod"):
            template = doc.get("spec", {}) or {}
            pod_spec = (
                template.get("template", {}).get("spec", {})
                if kind != "Pod"
                else template
            )
            for container in (pod_spec or {}).get("containers", []) or []:
                for port_spec in container.get("ports", []) or []:
                    host_port = port_spec.get("hostPort")
                    if host_port:
                        proto = str(port_spec.get("protocol", "TCP")).lower()
                        found.append((path, "hostPort", int(host_port), proto))
    return found


def check_unregistered(entries: list[dict], repo_root: pathlib.Path) -> list[str]:
    registered_ports = {(e["port"], e["proto"]) for e in entries}
    errors = []
    for path, kind, port, proto in find_exposed_ports(repo_root):
        if (port, proto) not in registered_ports:
            errors.append(
                f"{path.relative_to(repo_root)}: {kind} exposes {proto}/{port} "
                f"with no inventory/ports.yaml entry"
            )
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", default=".", type=pathlib.Path)
    args = parser.parse_args()
    repo_root = args.repo_root.resolve()

    entries = load_registry(repo_root)
    errors = check_duplicates(entries) + check_unregistered(entries, repo_root)

    if errors:
        print(f"check-ports.py: {len(errors)} problem(s) found:\n", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        return 1

    print(f"check-ports.py: OK — {len(entries)} registry entries, no duplicates, no unregistered exposures")
    return 0


if __name__ == "__main__":
    sys.exit(main())
