# k3s role

**Cutover applied 2026-09-28** (see `changelog/2026-09.md`) — the systemd drop-in
(`/etc/systemd/system/k3s.service.d/tailscale.conf`) is gone; k3s now runs from
`/etc/rancher/k3s/config.yaml` with the identical flags plus the new
`kubelet-arg` image-GC thresholds (75%/60%). Verified: node stayed `Ready` through the restart,
all 28 ArgoCD Applications' Sync/Health status identical before/after, `kubectl get --raw
/api/v1/nodes/vps/proxy/configz` confirms the new kubelet thresholds took effect, tailscale0
interface/IP unchanged, `https://argocd.upayan.dev/` still `200`.

On a host that already has `/etc/rancher/k3s/config.yaml` (the live node) this role still renders
`config.yaml.pending` first and never restarts k3s automatically — the steps below are kept for the
next time this role's rendered config changes and needs re-applying. On a **fresh** host, where
there is no config to protect, it renders `config.yaml` directly and before the installer runs,
because k3s's first start reads it (P4-02).

```bash
# 1. Snapshot first
ssh vps "mkdir -p /root/pre-k3s-config-cutover && k3s etcd-snapshot save --name pre-k3s-config-cutover --dir /root/pre-k3s-config-cutover"

# 2. Diff and review
ssh vps "diff -u /etc/rancher/k3s/config.yaml /etc/rancher/k3s/config.yaml.pending 2>&1 || true"

# 3. Apply (maintenance window — this restarts the control plane)
ssh vps '
  set -e
  mv /etc/rancher/k3s/config.yaml.pending /etc/rancher/k3s/config.yaml
  rm -f /etc/systemd/system/k3s.service.d/tailscale.conf
  systemctl daemon-reload
  systemctl restart k3s
'

# 4. Validate
kubectl get nodes
kubectl get applications -n argocd -o wide   # compare against the pre-cutover snapshot
```

Rollback: restore `/etc/systemd/system/k3s.service.d/tailscale.conf`, remove
`/etc/rancher/k3s/config.yaml`, `systemctl daemon-reload && systemctl restart k3s`; if that doesn't
recover, restore the etcd snapshot from step 1 per `../../docs/runbooks/recover-k3s.md`.
