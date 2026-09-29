# ICAR-CRIDA contingency-plan corpus (the meghmitra ingest job)

**Status: the application this served is being replaced, and the job manifest is deleted.** This runbook
exists because the job encoded knowledge that took real debugging to acquire, and the manifest that held it
(`k8s/apps/meghmitra/jobs/ingest-corpus-job.yaml`, a ConfigMap-embedded `download_dacp.py`) is gone from the
working tree as of 2026-09-29 (CLEAN-001). The full script is in git history — `git log --follow --
k8s/apps/meghmitra/jobs/ingest-corpus-job.yaml` — and belongs in the owning application's repository if it is
ever needed again, not here.

## What it did

Downloaded every **District Agriculture Contingency Plan (DACP)** PDF from ICAR-CRIDA's public index
(`https://www.icar-crida.res.in/Crop_Contingency_Plan.html`) into `data/raw/<State>/<filename>.pdf`, for the
corpus the application then ingested. It ran as a one-off `Job` applied from this repository — never a CronJob,
never in an image build — because it needs outbound internet to one specific government host and writes into
the application's data tree.

## The four things that cost time, kept here so they cost it only once

1. **The index HTML is malformed.** Many `<a>` tags are never closed, so a strict parser refuses it. The
   script scanned sequentially for a state header and took every following PDF anchor as belonging to that
   state, tolerating the missing `</a>`. A tolerant scan, not a parser.
2. **Cluster egress to `icar-crida.res.in` is slow and flaky, and it is a hard prerequisite.** The first
   request gates the whole run, and repeated multi-attempt timeouts were observed at a bare 30 s with no
   retry — the script used a generous timeout *with* retries. A one-off blip and a systemic problem look
   identical here; treat the first fetch's failure as the latter.
3. **The server's directory casing disagrees with the index page's links** for a handful of documents
   (case-sensitive IIS on the backend). The workaround was to retry with a lowercased directory component
   before giving up. This is why a handful of files needed two attempts and why "it failed once" was not
   evidence of a broken document.
4. **One bad file must not destroy the batch.** Downloads ran in a `ThreadPoolExecutor` (`--workers 12`) with
   per-file error isolation and a `subprocess` timeout that a hung connection could still outlive — hence the
   explicit handling around each future rather than around the pool.

## Behaviour worth relying on if it is revived

- **Idempotent:** an existing file that is non-empty, larger than 1 KB and starts with `%PDF` is skipped, so
  re-running picks up only documents ICAR-CRIDA adds or renames. There is no manifest of what "should" exist —
  the index is the source of truth on every run.
- **Writes are atomic-ish:** each download goes to a `.part` file and is renamed into place, so an interrupted
  run leaves no half-PDF that a later run would treat as valid.
- **Destination is the application's data tree**, so anything reviving this must decide where that tree lives
  now — under the replacement application it is not the same path.
