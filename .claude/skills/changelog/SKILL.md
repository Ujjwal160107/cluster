---
name: changelog
description: Forensic changelog format for this repo — when an entry is required and how to write one, for both git-tracked changes and break-glass kubectl operations
---

# Changelog (forensic timeline)

`changelog/` is the single source of truth for "what happened to this cluster, when, why, and how
it was verified" — for both git-tracked changes and break-glass `kubectl` operations that git
never sees. `git log` alone is not enough: it has no record of break-glass ops, no verification
evidence, and no cost/rollback context.

## When an entry is required

Every time, no exceptions:
- Any commit that touches `k8s/` (feature, fix, cleanup, config change).
- Any break-glass `kubectl` write permitted by `CLAUDE.md` rule 2 (rollout restart, delete pod,
  hard-refresh annotate, root-app bootstrap) — **and any other live cluster mutation**, e.g. the
  ad-hoc PVC/PV cleanup pattern in `changelog/2026-08.md`.
- Incidents/outages discovered even if no fix was applied yet (log the investigation).

Read-only investigation that changes nothing does **not** need an entry.

## Where

`changelog/YYYY-MM.md`, one file per month, newest entries at the top. If the current month's
file doesn't exist yet, create it — see `changelog/README.md` → "Starting a new month" — and add
its row to the index table there.

**Append-only.** Never edit or delete a past entry; if something was wrong, append a new entry
that corrects it.

## Entry format

```
### ~HH:MM IST — <short title>
- **Actor:** human | agent (session/name)
- **Type:** git commit `<sha>` | break-glass kubectl | incident
- **Trigger:** why this happened — omit if obvious from context
- **Change:** exactly what changed — concrete resource names, sizes, files, not vague summaries
- **Reason:** why this change, not just what
- **Verification:** the specific command/output that proved it worked
- **Cost impact:** quantify if it touches billed resources (volumes, servers, IPs)
- **Rollback:** how to undo — `git revert <sha>`, restore-from-backup path, or "N/A: nothing to revert"
```

Timestamps are IST (`+05:30`), matching this repo's git commit timestamps.

## Workflow

1. **Git-tracked change:** write the manifest edit and the changelog entry in the *same commit*.
2. **Break-glass kubectl:** since nothing lands in git automatically, treat the changelog entry
   itself as the commit that must happen — write it and `git push` right after the kubectl
   action (or right before, if there's time to plan a risky one). Be exhaustive: full
   investigation trail, exact resource identifiers (PVC/PV UUIDs, pod names), and how data loss
   was ruled out before anything destructive ran.
3. Never defer "I'll log it later" — the entry is part of the change, not a follow-up task.
