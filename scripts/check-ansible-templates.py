#!/usr/bin/env python3
"""Parse every Ansible Jinja template, so a syntax error fails CI instead of a playbook run.

Why this exists: on 2026-09-28 a backup template contained the shell array-length expansion, whose
first two characters are also Jinja's comment opener. `ansible-playbook --syntax-check` passed — it
never renders templates — and `ansible-lint` passed too. The failure only appeared when the role ran
against the host, with the distinctly unhelpful message "Missing end of comment tag", and it took two
attempts to fix because the first version of the warning comment about it contained the same sequence.

A template that cannot be parsed is a guaranteed failure at deploy time, so it belongs here: cheap,
no host needed, no credentials.

Usage: scripts/check-ansible-templates.py [root]   (default root: ansible/)
Exit: 0 all templates parse · 1 otherwise.
"""
from __future__ import annotations

import pathlib
import sys

try:
    import jinja2
except ImportError:  # pragma: no cover - CI installs ansible-core, which brings Jinja2
    print("jinja2 is not installed; install ansible-core (or jinja2) first", file=sys.stderr)
    sys.exit(2)


def main(argv: list[str]) -> int:
    root = pathlib.Path(argv[1] if len(argv) > 1 else "ansible")
    if not root.is_dir():
        print(f"not a directory: {root}", file=sys.stderr)
        return 2

    templates = sorted(p for p in root.rglob("*.j2") if p.is_file())
    if not templates:
        print(f"no .j2 templates found under {root} — has the layout changed?")
        return 0

    env = jinja2.Environment()
    failures: list[tuple[pathlib.Path, jinja2.TemplateSyntaxError]] = []
    for path in templates:
        try:
            env.parse(path.read_text(encoding="utf-8"))
        except jinja2.TemplateSyntaxError as exc:
            failures.append((path, exc))

    for path, exc in failures:
        print(f"{path}:{exc.lineno}: {exc.message}", file=sys.stderr)
        # The commonest cause here by far deserves naming, because the message above does not hint at it.
        if "comment" in (exc.message or "").lower():
            print(
                "  hint: a Jinja comment marker appeared by accident. The usual culprit is a shell "
                "construct that begins with the same two characters — an array-length expansion in a "
                "`${...}` expression. Use a counter loop instead.",
                file=sys.stderr,
            )

    if failures:
        print(f"\n{len(failures)} of {len(templates)} templates failed to parse", file=sys.stderr)
        return 1
    print(f"{len(templates)} Jinja templates parsed cleanly")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
