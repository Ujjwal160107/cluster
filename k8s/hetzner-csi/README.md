Hetzner Cloud CSI (manifests)

This folder helps you produce and apply full Kubernetes manifests for the Hetzner Cloud CSI driver without installing the chart server-side.

Preferred workflow (produces a single `rendered-manifests.yaml` you can check in or apply):

1. Export your Hetzner token locally:

```bash
export HCLOUD_TOKEN=your_token_here
```

2. Create the `kube-system` secret (or edit `secret.yaml` and apply):

```bash
kubectl apply -f secret.yaml
```

3. Render the chart to YAML (requires `helm`):

```bash
helm repo add hetzner https://charts.hetzner.cloud
helm repo update
./render.sh
```

4. Apply the rendered manifests:

```bash
kubectl apply -f rendered-manifests.yaml
```

Notes:

- `render.sh` calls `helm template` against `hetzner/hcloud-csi` and writes `rendered-manifests.yaml`.
- If you cannot run `helm` on the machine you are preparing manifests on, run the same `helm template` command on any machine with `helm`, then copy `rendered-manifests.yaml` into this folder and apply.
- After applying, verify driver pods in `kube-system` and that a StorageClass (provisioner `csi.hetzner.cloud`) exists.

If you want me to render the chart for you and commit the generated `rendered-manifests.yaml`, say so and provide the `HCLOUD_TOKEN` or confirm I should render without the token (the secret will still need to be created manually).
