# k8s/bootstrap/

The two files that start a cluster from nothing. Everything else in `k8s/` is reconciled by ArgoCD
*from* `k8s/argocd/`; these are the bootstraps that make that possible.

- **`root-app.yaml`** — the app-of-apps `Application` (`root`). It watches this repository's
  `k8s/argocd/` recursively and is the single object that turns a bare cluster into the full set of
  Applications. It is applied by hand, once: nothing inside git can create it.
- **`bootstrap.sh`** — the order in which a **fresh** cluster gets there (P4-04). `root-app.yaml`
  alone is not enough, for the three reasons below.

## Why a script and not just `kubectl apply -f root-app.yaml`

1. **ArgoCD is a Helm release, not a manifest in this repo.** The live cluster runs the
   `argo/argo-cd` chart at **7.9.1**; its values are `k8s/platform/argocd/values.yaml`. (After
   bootstrap, the `argocd` Application adopts this release, but it has to exist first.)
2. **The app-of-apps repo is private.** `root-app.yaml` points at
   `https://github.com/upayanmazumder/cluster`, and ArgoCD needs the repo credentials committed
   SOPS-encrypted in `k8s/platform/argocd/secret/secrets.sops.yaml`. That file lives *in the repo
   ArgoCD is trying to fetch*, so it must be applied by hand before the root app can sync. Skipping
   this is the known failure mode: every Application reports
   `ComparisonError: failed to get git client for repo https://github.com/upayanmazumder/cluster`.
3. **ksops needs the age-cluster key.** It is deliberately never in git (the key-placement policy is
   part of the private archive, not the published tree); `bootstrap.sh` reads it from a file
   the operator exports from the password manager and installs it as the `argocd/sops-age` Secret.

`bootstrap.sh` performs exactly this order:

```
kubectl create namespace argocd
kubectl -n argocd create secret generic sops-age --from-file=keys.txt=<age-cluster key>
sops -d k8s/platform/argocd/secret/secrets.sops.yaml | kubectl apply -f -
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd --version 7.9.1 -n argocd -f k8s/platform/argocd/values.yaml
kubectl -n argocd rollout status deploy/argocd-repo-server
kubectl apply -f k8s/bootstrap/root-app.yaml
```

## Running it

```bash
# 1. Export the age-cluster private key from the password manager (P4-01) to a tmpfs path.
export AGE_CLUSTER_KEYS_FILE=/dev/shm/age-cluster/keys.txt

# 2. From the repository root:
k8s/bootstrap/bootstrap.sh
```

It is `shellcheck -S warning` clean, and it **fails closed**: if `AGE_CLUSTER_KEYS_FILE` is unset or
unreadable, or `kubectl`/`helm`/`sops` is missing, it exits before applying anything. That is
deliberate — a half-bootstrap that installs ArgoCD without a decryptable `sops-age` leaves a cluster
that can never reconcile.

**No secret is ever hard-coded or committed.** The script reads the one credential it needs from the
environment; the repo credentials come from the SOPS file it decrypts at run time.

Re-running is safe (namespace/Secret use `--dry-run=client | apply`, Helm uses `upgrade --install`)
but is not the normal path: after step 7 ArgoCD owns everything and changes go through git.

## Not yet verified

`bootstrap.sh` has **not** been exercised end-to-end on a throwaway server. In particular, whether
the self-managed `argocd` Application adopts the Helm-installed release cleanly is unconfirmed until
the DR-006 drill (P4-09) runs from `cluster` after the P6 cutover. The individual steps are the ones
documented in `docs/runbooks/recover-vm.md`, which *was* used by hand to bring the live cluster up.
