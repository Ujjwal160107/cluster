#!/usr/bin/env python3
"""Check that every relative Markdown link in the published tree resolves.

The tree this validates is the one that actually ships: the export in
`scripts/private/export-public.sh` copies an allowlist of tracked files and excludes
`docs/plans/`, `docs/reports/`, `scripts/private/`, `archived/` and `k8s/GUIDE.md`, so a link
from a published file into any of those is broken *in the published repository even though it
resolves in the private one*. This script therefore fails twice over:

  1. a relative link whose target does not exist; and
  2. a relative link that points inside a path the export never publishes.

Fenced code blocks and inline code spans are ignored (a link shown as example text is not a link),
as are absolute URLs, `mailto:` links and pure `#anchor` links.

Scope: every `*.md` under the repository root except `docs/plans/`, `docs/reports/`, `archived/`
and `changelog/` (the last is scanned as content, but its own links are not held to this standard
because the export redacts it).

Exit 0 when clean, 1 when any link fails, 2 on a usage error. Output is deterministic: files are
walked in sorted order and every failure is printed on one line.

Usage: python3 scripts/check-links.py
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

# Directories whose Markdown is not scanned at all.
SKIP_DIRS = {"docs/plans", "docs/reports", "archived", "changelog"}
# Directories that never reach the published tree, so nothing published may link into them.
UNPUBLISHED = ("docs/plans/", "docs/reports/", "scripts/private/", "archived/")
# Any other path that is never exported to the published tree.
UNPUBLISHED_FILES = ("k8s/GUIDE.md",)
# Non-content directories, skipped wherever they appear.
IGNORE_ANYWHERE = {".git", ".terraform", ".ansible", ".vscode", "node_modules"}

FENCE_RE = re.compile(r"^\s*(```|~~~).*?^\s*\1\s*$", re.S | re.M)
INLINE_CODE_RE = re.compile(r"`[^`\n]*`")
LINK_RE = re.compile(r"!?\[[^\]]*\]\(\s*<?([^)\s>]+)>?\s*\)")


def iter_markdown_files(root: Path):
    for path in sorted(root.rglob("*.md")):
        rel = path.relative_to(root)
        parts = set(rel.parts)
        if parts & IGNORE_ANYWHERE:
            continue
        rel_dir = "/".join(rel.parts[:-1])
        if any(rel_dir == d or rel_dir.startswith(d + "/") for d in SKIP_DIRS):
            continue
        yield path, rel


def strip_code(text: str) -> str:
    return INLINE_CODE_RE.sub("", FENCE_RE.sub("", text))


def check_link(root: Path, md_path: Path, target: str) -> str | None:
    if target.startswith(("#", "/")) or "://" in target or target.startswith("mailto:"):
        return None
    path_part = target.split("#", 1)[0].split("?", 1)[0]
    if not path_part:
        return None
    resolved = (md_path.parent / path_part).resolve()
    try:
        rel = resolved.relative_to(root.resolve()).as_posix()
    except ValueError:
        return f"target escapes the repository: {target}"

    if rel == UNPUBLISHED_FILES[0] or any(rel.startswith(p) for p in UNPUBLISHED):
        return f"points into a path the export never publishes: {rel}"
    if not resolved.exists():
        return f"target does not exist: {rel}"
    return None


def main() -> int:
    if len(sys.argv) != 1:
        print(f"error: takes no arguments (got: {' '.join(sys.argv[1:])})", file=sys.stderr)
        return 2

    root = Path(__file__).resolve().parent.parent
    files = 0
    links = 0
    failures: list[str] = []

    for md_path, rel in iter_markdown_files(root):
        files += 1
        text = strip_code(md_path.read_text(encoding="utf-8", errors="replace"))
        for lineno, line in enumerate(text.splitlines(), start=1):
            for match in LINK_RE.finditer(line):
                links += 1
                problem = check_link(root, md_path, match.group(1))
                if problem:
                    failures.append(f"{rel}:{lineno}: [{match.group(1)}] {problem}")

    for failure in failures:
        print(failure)
    print(
        f"checked {links} relative link(s) in {files} file(s); "
        f"{len(failures)} unresolved"
    )
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
