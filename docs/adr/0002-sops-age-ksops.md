# 0002. SOPS + age, decrypted by ksops in ArgoCD's repo-server

- **Status:** Accepted
- **Date:** 2026-09-28

## Context

Secrets have to live next to the manifests that use them, or a rebuild from git produces a cluster that
cannot start. Before this decision, that meant ~35 plaintext `Secret` manifests and several `.env`
files in git, including a Hetzner API token that could delete the server, a GitHub token with write
access to two organisations, and a Cloudflare Origin CA private key. Deleting a file does not remove it
from history, so the values are public to anyone who ever cloned the repo — and the cluster is the
thing being protected.

A second requirement rules out several convenient designs: ArgoCD must be able to sync unattended,
including after a node rebuild, with no human present to unlock anything.

## Decision

**SOPS with `age` recipients is the only secret mechanism, and ksops is how ArgoCD decrypts it.**

- **Two recipients, either of which can decrypt:** `age-ops` (the owner's workstation, plus an offline
  copy) and `age-cluster` (installed once as the `argocd/sops-age` Secret so the repo-server can decrypt
  during a sync with nobody present). The private keys are never committed — `argocd/sops-age` is the
  one cluster object that exists only because bootstrap put it there.
- **Partial encryption for Kubernetes manifests.** `creation_rules` for `**/secrets.sops.yaml` set
  `encrypted_regex: ^(data|stringData)$`, so `kind`, `apiVersion` and `metadata` stay readable and
  diffable and only the values are ciphertext.
- **Full-value encryption where the file is not a manifest:** Ansible group vars are decrypted by the
  `community.sops` vars plugin on the control machine; `terraform/secrets.enc.env` is read by
  `sops exec-env` so no plaintext credential is ever written to disk.
- **Decryption happens in-cluster:** the repo-server installs a pinned `ksops` and points
  `SOPS_AGE_KEY_FILE` at the mounted `sops-age` Secret, so the `kustomize` build ArgoCD runs for each
  Application resolves the real Secret.
- **Plaintext `Secret` manifests are structurally prevented:** `scripts/check-secrets.sh` fails if a
  file named `secrets.sops.yaml` lacks a `sops:` block with `age:` recipients, or if any `Secret` under
  the manifests carries non-empty values without SOPS metadata. It needs no decrypt key, so CI can run
  it.

## Alternatives rejected

- **Sealed Secrets.** Needs a controller in-cluster holding the private key, secrets are bound to the
  cluster's key, and there is no partial encryption — the whole blob is opaque, so every secret manifest
  becomes undiffable.
- **External Secrets Operator + a cloud secret store.** Adds a component and a cloud credential *inside*
  the cluster, and moves the source of truth out of git — the opposite of the goal.
- **Plaintext in a private repo.** This is what existed; the history is the leak, and it is why every
  credential had to be rotated rather than just re-encrypted.
- **`helm-secrets` for the Helm values — no longer needed (2026-09-29, SEC-003).** It was the candidate
  for `k8s/apps/vcap/values/*.yaml`, on the reasoning that a ksops generator cannot be reached through
  `kustomize --enable-helm` over a git-sourced chart. The blocker was real, but the conclusion was too
  strong: ArgoCD **multi-source** lets the chart stay a Helm source while a second source in this repo
  carries the SOPS Secrets, so neither `helm-secrets` nor publishing the chart was required. See the
  known gap below.

## Consequences

- The public repository can hold the ciphertext, so **secrets stop being a reason to keep the repo
  private**. What must not be published is the history containing the plaintext — hence the
  fresh-history rule.
- **Encryption is not rotation.** Every value in git is the *original* credential, still valid until it
  is rotated, and the plaintext remains in the private history. Rotating is what neutralises the leak.
- `age` key custody is a hard dependency: losing both private keys loses every git-held secret, so an
  offline copy is part of the design (not a nice-to-have).
- A hand-edited `secrets.sops.yaml` breaks its `mac` and fails at sync time rather than silently
  producing a wrong value — verified by re-reading with `sops -d` before committing.
- Anything that needs a secret at *runtime* now needs either a synced Secret or a host-side decrypt;
  host-side, the Ansible role renders `/etc/vps-backup/env` from SOPS, so the restic password is never
  in a unit file.
- **Known gap, closed 2026-09-29 (SEC-003):** `k8s/apps/vcap/values/backend-{dev,staging}.yaml` were
  plaintext Helm values carrying credentials, with a matching `.gitleaks.toml` allowlist. The credentials
  moved to `k8s/apps/vcap/secrets/{dev,staging}/secrets.sops.yaml` (multi-source, see above), **the
  allowlist is deleted**, and `gitleaks` over the tree with it removed reports no leaks — evidence it was
  not hiding anything else. `frontend-staging.yaml` never carried values, only the name of a Secret it
  references.

## Evidence

`.sops.yaml` (creation rules), `k8s/platform/argocd/values.yaml` (the repo-server ksops initContainer,
pinned by digest), `k8s/platform/argocd/secret/`, `scripts/check-secrets.sh`, `ansible/ansible.cfg`
(vars plugin), and `docs/secrets.md`.
