#!/usr/bin/env bash
set -euo pipefail

CHART=hetzner/hcloud-csi
VERSION=2.20.0
NAMESPACE=kube-system
OUT=rendered-manifests.yaml

if ! command -v helm >/dev/null 2>&1; then
  echo "helm is required to render the chart. Install helm or run this script on a machine with helm."
  exit 2
fi

echo "Rendering $CHART (version $VERSION) to $OUT"
helm repo add hetzner https://charts.hetzner.cloud || true
helm repo update
helm template hcloud-csi "$CHART" --namespace "$NAMESPACE" --version "$VERSION" -f values.yaml > "$OUT"
echo "Wrote $OUT"
