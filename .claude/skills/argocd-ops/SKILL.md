---
name: argocd-ops
description: ArgoCD operational quick-reference — sync, refresh, rollback, diff, force-sync, logs, common failure modes and fixes
---

# ArgoCD operations quick-reference

## Status

```bash
kubectl get applications -n argocd -o wide        # all apps, sync + health
argocd app get <app-name>                         # detailed view
argocd app diff <app-name>                        # git desired vs cluster actual
argocd app history <app-name>                     # sync history + revisions
```

## Trigger sync / refresh

```bash
# Hard refresh (re-fetch git, detect changes) — preferred over argocd app sync
kubectl -n argocd annotate app <app> argocd.argoproj.io/refresh=hard --overwrite

# Sync root → cascades to all apps
kubectl -n argocd annotate app root argocd.argoproj.io/refresh=hard --overwrite

# Force sync (apply even if already Synced)
argocd app sync <app>

# Force sync + prune orphaned resources
argocd app sync <app> --prune
```

## Rollback

```bash
argocd app history <app>                    # list revisions
argocd app rollback <app> <revision>        # roll back (pauses auto-sync)

# Preferred: git revert so self-heal picks it up
git revert <sha> && git push origin main
```

## Inspect resources

```bash
kubectl get all -n <namespace>
kubectl describe pod -n <namespace> <pod>
kubectl get events -n <namespace> --sort-by=.lastTimestamp

kubectl logs -n <namespace> deployment/<name>
kubectl logs -n <namespace> deployment/<name> --previous   # crashed container

kubectl exec -it -n <namespace> deployment/<name> -- sh
```

## Common failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `OutOfSync` on Job | Jobs are immutable; re-apply fails | Convert to sync hook: `argocd.argoproj.io/hook: PreSync` + `BeforeHookCreation` |
| `OutOfSync` on replicas | KEDA owns `spec.replicas` | Add `ignoreDifferences` on `/spec/replicas` |
| App `Missing` | Folder deleted; `apps` list element still present | Remove the list element from `k8s/argocd/applicationsets/apps.yaml`, or restore folder |
| `ImagePullBackOff` | Wrong image or missing pull secret | Fix image path; add `imagePullSecret` to manifest |
| New app not appearing | No element in the `apps` list generator (apps are not auto-discovered), or namespace not in `projects/apps.yaml` | Add the list element + project namespace (`.claude/skills/app-onboarding/SKILL.md` §6–§7) |
| Ingress 404 / no TLS | Host not in DNS or Traefik default cert missing | Add Cloudflare A record; check `wildcard-upayan-dev-tls` Ready |
| `CrashLoopBackOff` | Bad env/config | `kubectl logs --previous`; fix in git |
| Stuck Terminating ns | Finalizers not released | Patch out finalizers (see below) |

## Stuck Terminating namespace

```bash
kubectl get namespace <ns> -o json \
  | python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" \
  | kubectl replace --raw /api/v1/namespaces/<ns>/finalize -f -
```

## Disable / re-enable auto-sync

```bash
argocd app set <app> --sync-policy none
argocd app set <app> --sync-policy automated --self-heal --auto-prune
```

## ApplicationSet debugging

```bash
kubectl get applicationsets -n argocd
kubectl describe applicationset apps -n argocd
```

## Image Updater

```bash
kubectl logs -n argocd deployment/argocd-image-updater   # auth/push errors

# Annotation reference on Applications:
argocd.argoproj.io/image-list: "app=ghcr.io/<owner>/<image>"
argocd.argoproj.io/write-back-method: git
argocd.argoproj.io/git-branch: main
```
