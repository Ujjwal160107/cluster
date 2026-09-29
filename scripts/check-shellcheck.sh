#!/usr/bin/env bash
# CI-007 (partial) — shellcheck over the repo's shell, including the Ansible shell templates.
#
# Two things this catches that nothing else did:
#
#   1. Ordinary shell defects in `scripts/*.sh`.
#   2. **A malformed `# shellcheck` directive**, which is worse than no directive: shellcheck parses
#      everything after the code list as a key=value pair and reports SC1125 ("Invalid key=value
#      pair? Ignoring the rest of this directive"), so the suppression silently does nothing and the
#      next reader believes a rule is handled when it is not. Two directives in
#      `ansible/roles/backup/templates/` were in that state until this ran — each had prose after the
#      code list (`disable=SC2086 — the strings are intentionally word-split`).
#
# The Ansible shell templates cannot be rendered here: CI holds no age key, and several of them
# interpolate SOPS-decrypted values. They do not need rendering for this to be useful — Jinja
# *expressions* (`{{ ... }}`) are replaced with a placeholder, which is enough because they always
# appear inside quotes or as a single command word. Jinja *blocks* (`{% ... %}`) would break that, so
# this refuses to check a template containing one rather than linting nonsense.
#
# Fail-closed on purpose: if shellcheck is missing, this exits non-zero. A linter that quietly does
# nothing is the failure mode this file exists to complain about.
#
# Run locally without installing shellcheck:
#   docker run --rm -v "$PWD:/repo:ro" koalaman/shellcheck:stable --version
#
# Usage: scripts/check-shellcheck.sh
# Exit: 0 clean, 1 on any finding or if shellcheck is unavailable.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "ERROR: shellcheck is not installed (see the header for the docker one-liner)." >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Shell scripts checked as-is.
mapfile -t plain < <(find "$repo_root/scripts" -maxdepth 1 -name '*.sh' | sort)

# Ansible shell templates, Jinja expressions replaced.
mapfile -t templates < <(find "$repo_root/ansible" -name '*.sh.j2' | sort)
rendered=()
for t in "${templates[@]}"; do
  if grep -q '{%' "$t"; then
    echo "ERROR: $t contains a Jinja block ({% %}), which the placeholder substitution below cannot" >&2
    echo "       handle. Lint it after rendering instead of ignoring it." >&2
    exit 1
  fi
  out="$tmp/$(basename "${t%.j2}")"
  sed 's/{{[^{}]*}}/PLACEHOLDER/g' "$t" >"$out"
  rendered+=("$out")
done

echo "check-shellcheck: ${#plain[@]} script(s) + ${#templates[@]} template(s)"

fail=0
# `-S warning` rather than `style`: the repo's shell is clean at every severity today, but style-level
# suggestions churn without catching bugs, and a lint step that cries wolf gets disabled.
if ! shellcheck -S warning -s bash -f gcc "${plain[@]}" "${rendered[@]}"; then
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "check-shellcheck: OK"
fi
exit "$fail"
