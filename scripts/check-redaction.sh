#!/usr/bin/env sh
# Publication gate for this repository (P5-04).
#
# The problem it solves: the redaction terms are exactly the strings that must never be published —
# personal addresses, a personal name, an old hostname, a path on the owner's workstation. A checker
# that *contains* them cannot be shipped in the repository it checks, and a checker whose terms live
# in a document is a rule that has not been implemented (measured: four personal addresses survived a
# "careful pass" that had the rule written down).
#
# So the terms live outside: the GitHub Actions secret `REDACTION_TERMS` on this repository, and the
# password manager. This script holds the *mechanism* and none of the terms, which is why it can be
# public. It refuses to run when the terms are absent rather than reporting a clean tree it never
# checked — the failure mode of every scanner that has been quietly switched off.
#
# The private repository's copy, which *does* name the terms, is `scripts/private/check-public-redaction.sh`;
# that one gates the export that builds this repository. This one gates this repository itself, after
# it exists, including its history — which the export-side check cannot see.
#
# Usage:
#   REDACTION_TERMS=$(printf 'term1\nterm2\n') scripts/check-redaction.sh            # tree
#   REDACTION_TERMS=... scripts/check-redaction.sh --history                        # tree + every commit
#
# Terms are newline-separated; blank lines and lines starting with `#` are ignored. Matching is
# FIXED-STRING (-F): these are literals, and a term containing a regex metacharacter must still match
# literally. Output is file names and commit ids only — never the matching line, because the matching
# line is usually the thing being redacted.
#
# Exit: 0 clean, 1 on any hit or if the check could not run.
set -u

history=0
case "${1:-}" in
  --history) history=1 ;;
  "" ) : ;;
  *) echo "usage: REDACTION_TERMS=<newline-separated> $0 [--history]" >&2; exit 2 ;;
esac

if [ -z "${REDACTION_TERMS:-}" ]; then
  echo "ERROR: REDACTION_TERMS is empty or unset — refusing to report a clean result for a check" >&2
  echo "       that never ran. Set it from the Actions secret or the password manager." >&2
  exit 1
fi

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root" || exit 1

# Build the -e arguments from the term list.
terms_file=$(mktemp)
trap 'rm -f "$terms_file"' EXIT
printf '%s\n' "$REDACTION_TERMS" | sed '/^[[:space:]]*$/d; /^#/d' > "$terms_file"
count=$(wc -l < "$terms_file" | tr -d ' ')
if [ "$count" -eq 0 ]; then
  echo "ERROR: REDACTION_TERMS contained only blank lines and comments." >&2
  exit 1
fi

set -- -F
while IFS= read -r term; do
  set -- "$@" -e "$term"
done < "$terms_file"

fail=0

# --- the tree ------------------------------------------------------------------------------------
hits=$(grep -rl "$@" --exclude-dir=.git --exclude-dir=node_modules . 2>&1) && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
  echo "FAIL: redaction terms present in the tree:" >&2
  # shellcheck disable=SC2086  # intentional: $hits is a newline-separated list; word-splitting is
                               # what puts one file per line. Quoting would print it as one line.
  printf '  %s\n' $hits >&2
  fail=1
elif [ "$rc" -ne 1 ]; then
  # Any other exit, or any diagnostic output, is a broken check, not a clean one.
  echo "ERROR: the tree scan could not run (grep exit $rc): $hits" >&2
  fail=1
elif [ -n "$hits" ]; then
  echo "ERROR: the tree scan produced diagnostics while matching nothing: $hits" >&2
  fail=1
fi

# --- git history ---------------------------------------------------------------------------------
# A working-tree scan cannot see a term that was committed and then removed. `git log -p --all`
# would, but it cannot say *which* commit, and a report nobody can act on gets ignored — so this
# walks the commits and uses `git grep` per commit, which names them.
if [ "$history" -eq 1 ]; then
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "ERROR: --history needs a git repository" >&2
    exit 1
  fi
  found=0
  while IFS= read -r sha; do
    if git grep -q "$@" "$sha" -- . 2>/dev/null; then
      echo "FAIL: redaction terms present in commit $sha ($(git log -1 --format=%s "$sha" 2>/dev/null))" >&2
      found=1
    fi
  done <<EOF
$(git rev-list --all 2>/dev/null)
EOF
  [ "$found" -eq 0 ] || fail=1
  echo "history: scanned $(git rev-list --all 2>/dev/null | wc -l | tr -d ' ') commit(s)" >&2
fi

if [ "$fail" -eq 0 ]; then
  echo "redaction check: clean ($count term(s), fixed-string, $( [ "$history" -eq 1 ] && echo 'tree + history' || echo 'tree only'))"
fi
exit "$fail"
