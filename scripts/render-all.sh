#!/usr/bin/env bash
# CI-001 — render EVERY kustomization directory, including the ones whose Secret comes from a
# ksops (sops + age) exec generator.
#
# Why this exists: `kubectl kustomize` cannot run the `ksops` exec plugin — CI holds no age key and
# no plugin binary — so those directories used to be skipped whole. 15 of the 21 kustomize
# directories take that path, so a typo in any of them, or in a resource they include, reached
# ArgoCD unnoticed. A generator that cannot run is not a reason to stop validating the rest of the
# directory.
#
# How: copy the trees this repo renders into a temp dir *preserving their structure*, drop the
# `ksops` entry from each `generators:` list (the Secret it would produce is validated separately by
# scripts/check-secrets.sh, which asserts real sops+age metadata without decrypting), then render
# each directory exactly as ArgoCD would build it.
#
# Preserving the structure matters, and not for tidiness (CLUSTER-001, 2026-09-28): kustomizations
# may reference shared `components/` above their own directory, and kustomize resolves those paths
# relative to the build root. Copying each directory in isolation — as this script first did — makes
# such references dangle, and the render then silently comes out short. That is the one failure mode
# a render check must never have, so the copy is of whole trees and the builds happen inside it.
#
# Usage: scripts/render-all.sh [OUTFILE]      (default: stdout; CI writes a file then pipes it to
#                                              kubeconform)
# Exit: 0 only if every directory rendered.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${1:--}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rendered="$tmp/all.yaml"
: >"$rendered"

# --- copy the rendered trees, structure intact --------------------------------------------------
tree="$tmp/tree"
mkdir -p "$tree"
for rel in k8s clusters; do
  [ -d "$repo_root/$rel" ] && cp -a "$repo_root/$rel" "$tree/$rel"
done

# --- strip ksops generators, in the copy --------------------------------------------------------
python3 - "$tree" <<'PY'
import os, sys, yaml

root = sys.argv[1]
stripped = []
for dirpath, _dirnames, filenames in os.walk(root):
    if "kustomization.yaml" not in filenames:
        continue
    path = os.path.join(dirpath, "kustomization.yaml")
    with open(path) as fh:
        kust = yaml.safe_load(fh) or {}
    generators = kust.get("generators")
    if not generators:
        continue
    keep = []
    for entry in generators:
        doc = None
        if isinstance(entry, str):
            try:
                with open(os.path.join(dirpath, entry)) as gf:
                    doc = next(iter(yaml.safe_load_all(gf)), None)
            except OSError:
                doc = None
        if isinstance(doc, dict) and doc.get("kind") == "ksops":
            continue
        keep.append(entry)
    if keep:
        kust["generators"] = keep
    else:
        kust.pop("generators")
        stripped.append(os.path.relpath(dirpath, root))
    with open(path, "w") as fh:
        yaml.safe_dump(kust, fh, sort_keys=False)

# Which directories lost their only generator to this strip. The render loop needs to know: a
# directory whose entire content *was* that generator has nothing left to build, and "kustomization
# is empty" is the correct answer for it, not a failure. Recording it here keeps the distinction
# exact — a directory that is empty for any other reason still fails the render.
with open(os.path.join(root, "..", "ksops-stripped.txt"), "w") as fh:
    fh.write("\n".join(sorted(stripped)) + ("\n" if stripped else ""))
PY

# --- render every kustomization, skipping Components ---------------------------------------------
total=0
failed=0
skipped_components=0
skipped_secrets=0

while IFS= read -r -d '' kfile; do
  dir=$(dirname "$kfile")
  rel=${dir#"$tree"/}

  # A `kind: Component` is not independently buildable: it is a fragment, and building it alone
  # yields whatever placeholder it carries (a Namespace named `…-placeholder`, for instance). It is
  # validated through the directories that include it, which is what the loop below does.
  if grep -qE '^kind: *Component *$' "$kfile"; then
    echo "-- $rel (Component — rendered via its parents, skipped standalone)" >&2
    skipped_components=$((skipped_components + 1))
    continue
  fi

  total=$((total + 1))
  if kubectl kustomize "$dir" >>"$rendered" 2>"$tmp/err"; then
    echo "== $rel" >&2
  elif grep -qxF "$rel" "$tmp/ksops-stripped.txt" 2>/dev/null && grep -q 'kustomization.yaml is empty' "$tmp/err"; then
    # Legitimately secrets-only (SEC-003): its whole content was the ksops generator, so with the
    # generator stripped there is nothing left to build. That is the correct answer, not a failure.
    # The Secret it produces is still validated — scripts/check-secrets.sh asserts real sops+age
    # metadata for every secrets.sops.yaml without decrypting it. Counted as skipped, like a
    # Component, so the arithmetic below stays honest.
    echo "-- $rel (secrets-only: its only generator was ksops; secrets.sops.yaml is validated by check-secrets.sh)" >&2
    total=$((total - 1))
    skipped_secrets=$((skipped_secrets + 1))
  else
    echo "FAILED: $rel" >&2
    sed 's/^/    /' "$tmp/err" >&2
    failed=$((failed + 1))
  fi
  printf -- '---\n' >>"$rendered"
done < <(find "$tree" -name kustomization.yaml -print0 | sort -z)

if [ "$out" != "-" ]; then
  cp "$rendered" "$out"
else
  cat "$rendered"
fi

echo "render-all: $((total - failed))/$total directories rendered" >&2
if [ "$failed" -ne 0 ]; then
  echo "render-all: FAILED ($failed)" >&2
  exit 1
fi
