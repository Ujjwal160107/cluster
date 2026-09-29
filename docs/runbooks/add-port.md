# Runbook: add a new externally-reachable port

This one is usable **today** — the port registry infrastructure it depends on
(`inventory/ports.yaml`, `scripts/check-ports.py`, `docs/ports.md`) already exists (S1).

## Steps

1. **Check the registry** for collisions: [`../ports.md`](../ports.md) (human-readable) or
   [`../../inventory/ports.yaml`](../../inventory/ports.yaml) (source of truth).

2. **Check live host listeners** — the registry can drift from reality:
   ```bash
   ssh vps "ss -Hltnp; ss -Hlunp"
   kubectl get svc -A -o wide | grep -E 'NodePort|LoadBalancer'
   ```

3. **Check the firewall.** A Hetzner Cloud Firewall **does** exist now (S2), but it is deliberately
   **permissive** — it allows 22, 80, 443, 6443, 5432, 5433, udp/41641 and icmp from anywhere, and
   nothing else. So a new port is *not* automatically reachable from the internet, but neither is it
   protected by policy: check `terraform/firewall.tf` in the `cluster` checkout
   (`cluster/terraform/firewall.tf`) and decide whether the new port needs a rule
   (permanent) or a break-glass one. Anything you expose via `NodePort`/`LoadBalancer`/`hostPort`
   without a matching firewall rule will be reachable from inside the cluster and the tailnet, and
   blocked from the internet — which is usually what you want, but state it explicitly in the
   registry entry's `firewall_rule` field.

4. **Add an entry to `inventory/ports.yaml`** with every required field: `port`, `proto`,
   `service`, `k8s_service`, `namespace`, `owner`, `scope` (`internal`/`tailnet`/`public`),
   `status` (`live`/`target`/`remove`), `reason`, `firewall_rule`, `ingress`, `auth`, `temporary`,
   `expires`.

5. **Validate the registry**:
   ```bash
   python3 scripts/check-ports.py
   ```
   Fails if your new entry duplicates an existing `(port, proto, scope)` pair with `status: live`
   or `target`, or if a `NodePort`/`LoadBalancer` Service/`hostPort` in `k8s/` has no matching
   registry entry at all. Fix any reported collision before continuing.

6. **Add the actual manifest** (Service, Ingress, or container `hostPort`) under `k8s/apps/<app>/`
   following the conventions in [`../../AGENTS.md`](../../AGENTS.md).

7. **Update [`../ports.md`](../ports.md)'s table by hand** to match the new YAML entry (no
   generator script yet — keep them in sync manually).

8. **Commit everything together** — the registry entry, the manifest, and `docs/ports.md` — with a
   changelog entry per [`../../.claude/skills/changelog/SKILL.md`](../../.claude/skills/changelog/SKILL.md).
   Push to `main`.

## Related

- [`../ports.md`](../ports.md) / [`../../inventory/ports.yaml`](../../inventory/ports.yaml)
- [`../networking.md`](../networking.md) — firewall layers this port will sit behind
