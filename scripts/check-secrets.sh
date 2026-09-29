#!/usr/bin/env bash
# Two structural checks over the secrets in this repo. Neither decrypts
# anything and neither needs an age/SOPS key -- CI never holds a decrypt key.
#
# 1. Any file named `secrets.sops.yaml`/`.yml` must have SOPS' `sops:` metadata
#    block with `age:` recipients. Plaintext YAML never has this, so this
#    catches "forgot to run `sops -e`" and hand-edits that broke the MAC.
#
# 2. No plaintext `Secret` manifest may carry real values under `k8s/`. Every
#    app Secret was converted to the SOPS+ksops pattern on 2026-09-28; this is
#    the guard that stops a new plaintext one from being committed alongside
#    it. A `Secret` with an empty `data:`/`stringData:` (a template such as
#    `k8s/hetzner-csi/`, whose values are commented out) is allowed.
set -euo pipefail

fail=0
while IFS= read -r -d '' f; do
  if ! grep -q '^sops:' "$f"; then
    echo "FAIL: $f has a secrets.sops.yaml name but no 'sops:' metadata block — looks unencrypted"
    fail=1
  fi
  if ! grep -qE '^\s*age:' "$f"; then
    echo "FAIL: $f has no 'age:' recipients under sops: — not encrypted with age"
    fail=1
  fi
done < <(find k8s ansible terraform -type f \( -name 'secrets.sops.yaml' -o -name 'secrets.sops.yml' \) -print0 2>/dev/null)

python3 - <<'PY' || fail=1
import sys, pathlib, yaml

bad = []
for f in sorted(pathlib.Path("k8s").rglob("*.yaml")):
    try:
        docs = list(yaml.safe_load_all(f.read_text()))
    except Exception:
        continue  # not YAML / kustomize fragments: kubeconform's job, not this one
    for d in docs:
        if not isinstance(d, dict) or d.get("kind") != "Secret":
            continue
        if "sops" in d:  # encrypted by SOPS; values are ciphertext
            continue
        values = d.get("data") or d.get("stringData") or {}
        real = [k for k, v in values.items() if v not in (None, "")]
        if real:
            bad.append(f"{f} ({d.get('metadata', {}).get('name')}): {len(real)} plaintext value(s)")

for b in bad:
    print(f"FAIL: plaintext Secret with real values — {b}")
if bad:
    print("FAIL: every Secret manifest under k8s/ must be SOPS-encrypted "
          "(secrets.sops.yaml + a ksops secret-generator.yaml), per docs/secrets.md")
    sys.exit(1)
print("OK: no plaintext Secret manifest carries values under k8s/")
PY

# 3. P5-03: a file whose *name* says `secrets.sops.yaml` proves nothing about its contents. This
#    asserts the ciphertext itself, per `.sops.yaml`'s two creation rules:
#      - `k8s/…` files encrypt only `data`/`stringData` (a Secret manifest stays diffable), so every
#        value under those two keys must be `ENC[…]`;
#      - `ansible/…` and `terraform/…` files are full-value encrypted, so *every* leaf must be.
#    Before this, the only guard was `sops:` metadata existing, which a hand-written file can fake —
#    and gitleaks could not help because its path allowlist skipped exactly these filenames (removed
#    in the same change).
python3 - <<'PY' || fail=1
import pathlib, re, sys, yaml

ENC = re.compile(r"^ENC\[AES256_GCM,.*\]$", re.S)
bad = []

def leaves(node, path=()):
    if isinstance(node, dict):
        for k, v in node.items():
            yield from leaves(v, path + (str(k),))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from leaves(v, path + (str(i),))
    elif node is not None:
        yield path, node

files = sorted(
    p for root in ("k8s", "ansible", "terraform") if pathlib.Path(root).is_dir()
    for p in pathlib.Path(root).rglob("secrets.sops.y*ml")
)
for f in files:
    try:
        docs = [d for d in yaml.safe_load_all(f.read_text()) if d]
    except Exception:
        bad.append(f"{f}: not parseable as YAML (a full-file SOPS `.env` should not carry this name)")
        continue
    is_k8s_secret = any(isinstance(d, dict) and d.get("kind") == "Secret" for d in docs)
    for d in docs:
        if not isinstance(d, dict):
            continue
        if is_k8s_secret:
            for section in ("data", "stringData"):
                for key, val in (d.get(section) or {}).items():
                    if val in (None, ""):
                        continue  # an absent value is not a leaked one — same rule as check 2
                    if not (isinstance(val, str) and ENC.match(val.strip())):
                        bad.append(f"{f}: {d.get('metadata', {}).get('name')}.{section}.{key} is not SOPS ciphertext")
        else:
            for path, val in leaves(d):
                if path and path[0] == "sops":
                    continue  # sops' own metadata block is deliberately plaintext
                if val in (None, ""):
                    continue  # an absent value is not a leaked one
                if not (isinstance(val, str) and ENC.match(val.strip())):
                    bad.append(f"{f}: {'/'.join(path)} is not SOPS ciphertext")

for b in bad:
    print(f"FAIL: {b}")
if bad:
    print("FAIL: every value in a SOPS file must be ciphertext — a plaintext leaf means either "
          "`sops -e` was not run or the encrypted_regex does not cover it")
    sys.exit(1)
print(f"OK: all {len(files)} SOPS file(s) carry ciphertext at every encrypted leaf")
PY

if [ "$fail" -eq 0 ]; then
  echo "OK: every secrets.sops.yaml file has valid sops+age metadata"
fi
exit "$fail"
