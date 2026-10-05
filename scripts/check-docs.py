#!/usr/bin/env python3
"""Docs gate: AGENT-STANDARD.md version header + every relative markdown link resolves."""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)[^)]*\)")
errors = []

head = (ROOT / "AGENT-STANDARD.md").read_text().splitlines()[0]
if not re.fullmatch(r"# .+ — v\d+\.\d+\.\d+", head):
    errors.append(f"AGENT-STANDARD.md: first line is not a '# <title> — vX.Y.Z' header: {head!r}")

agents = ROOT / "AGENTS.md"
if agents.read_text().count("\n") > 90:
    errors.append("AGENTS.md exceeds 90 lines")

for md in sorted(ROOT.rglob("*.md")):
    if ".git" in md.relative_to(ROOT).parts or ".worktrees" in md.relative_to(ROOT).parts:
        continue
    in_fence = False
    for n, line in enumerate(md.read_text().splitlines(), 1):
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
        if in_fence:
            continue
        for target in LINK.findall(line):
            if re.match(r"[a-z][a-z0-9+.-]*:", target) or target.startswith("#"):
                continue
            path = (md.parent / target.split("#")[0]).resolve()
            if not path.exists():
                errors.append(f"{md.relative_to(ROOT)}:{n}: broken link {target}")

for e in errors:
    print(e, file=sys.stderr)
print(f"check-docs: {'FAIL' if errors else 'ok'} ({len(errors)} problems)")
sys.exit(1 if errors else 0)
