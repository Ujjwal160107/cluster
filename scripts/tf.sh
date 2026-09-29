#!/usr/bin/env bash
# The only sanctioned way to run Terraform for this cluster (P3-05).
#
# Three problems this exists to solve, each of which has already happened once in this
# infrastructure's short history:
#
#   1. **Two configurations, one state.** `vps/terraform` and `cluster/terraform` held the same
#      configuration against the same key (`s3://vps-tfstate/vps/terraform.tfstate`). A plan run
#      from the wrong checkout looks exactly like a correct one, and the difference only appears at
#      apply time. P3-06 removes the `vps` copy; this script is the guard for any checkout that
#      still has one, and for anyone who clones `vps` by habit.
#
#   2. **State is the single copy of what exists.** There is no versioning on the R2 bucket (see
#      `terraform/cloudflare.tf`) and no second Terraform root to rebuild from. Every operation that
#      can write state therefore snapshots it first — automatically, not by remembering.
#
#   3. **Provider credentials are one file outside the repository.** OD-10 moved
#      `secrets.enc.env` to `~/.config/vps/terraform/`; nothing in the repository names it, so
#      nothing in the repository can accidentally commit it.
#
# Usage:
#   scripts/tf.sh plan [-detailed-exitcode]
#   scripts/tf.sh apply /dev/shm/tfplan
#   scripts/tf.sh output -raw state_owner
#   scripts/tf.sh state list
#
# Exit codes: 0/1/2 from Terraform itself; 2 also means "refused before running anything".
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tf_dir="$repo_root/terraform"
secrets="${TF_SECRETS:-$HOME/.config/vps/terraform/secrets.enc.env}"
backup_dir="$HOME/.local/share/vps-tfstate-backup"

if [ $# -eq 0 ]; then
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi

# --- guard 1: this must be the owning repository -------------------------------------------------
origin=$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)
if ! printf '%s' "$origin" | grep -Eq 'github\.com[:/]upayanmazumder/cluster(\.git)?$'; then
  echo "REFUSING: origin is '${origin:-<none>}', not upayanmazumder/cluster." >&2
  echo "          Terraform for this cluster is owned by that repository only (OD-5)." >&2
  echo "          Check out github.com/upayanmazumder/cluster and run it from there." >&2
  echo "          The sentinel output 'state_owner' in the state names the owner too:" >&2
  echo "            sops exec-env \"\$TF_SECRETS\" 'terraform output -raw state_owner'" >&2
  exit 2
fi

if [ ! -f "$secrets" ]; then
  echo "REFUSING: no provider credentials at '$secrets'." >&2
  echo "          Restore it from the password manager (P5-05) or set TF_SECRETS to its path." >&2
  exit 2
fi

if ! command -v sops >/dev/null 2>&1; then
  echo "REFUSING: sops is not installed; cannot decrypt '$secrets'." >&2
  exit 2
fi

# --- guard 2: snapshot state before anything that can write it -----------------------------------
# `state pull` is read-only but is grouped with the writers on purpose: the subcommand that matters
# is `state push`, and a rule that distinguishes them is a rule someone has to remember.
cmd="$1"
case "$cmd" in
  apply|destroy|import|state)
    install -d -m 700 "$backup_dir"
    tmp=$(mktemp "$backup_dir/.pull.XXXXXX")
    chmod 600 "$tmp"
    if (cd "$tf_dir" && sops exec-env "$secrets" 'terraform state pull') > "$tmp" 2>/dev/null; then
      serial=$(jq -r '.serial // "unknown"' "$tmp" 2>/dev/null || echo unknown)
      snapshot="$backup_dir/$(date -u +%Y%m%dT%H%M%SZ)-serial${serial}.tfstate"
      mv "$tmp" "$snapshot"
      echo "tf.sh: state snapshot -> $snapshot (serial ${serial})" >&2
    else
      rm -f "$tmp"
      # Not fatal: the first-ever init has no state to pull. Reported rather than silent, because
      # "the snapshot step did nothing" is exactly what a person should not have to guess about.
      echo "tf.sh: WARNING — could not pull state to snapshot it (first run, or no backend access)." >&2
    fi
    ;;
esac

cd "$tf_dir"
echo "tf.sh: terraform $* (state: s3://vps-tfstate/vps/terraform.tfstate)" >&2

# `sops exec-env` takes a single *command string* (it runs it through a shell) — not a command plus
# argv. Passing them separately makes sops read the first word as the file to decrypt and fail with
# "missing file to decrypt", which is what this script did on its first run. `%q` quotes each
# argument for re-parsing, so `-var 'a="b c"'` survives intact.
printf -v tf_cmd 'terraform'
for arg in "$@"; do
  printf -v tf_cmd '%s %q' "$tf_cmd" "$arg"
done

exec sops exec-env "$secrets" "$tf_cmd"
