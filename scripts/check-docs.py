#!/usr/bin/env python3
"""Docs gate: AGENT-STANDARD.md version header + every relative markdown link resolves."""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)[^)]*\)")
REFDEF = re.compile(r"^ {0,3}\[[^\]]+\]:\s*<?([^\s>]+)")
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
errors = []

head = (ROOT / "AGENT-STANDARD.md").read_text().splitlines()[0]
if not re.fullmatch(r"# .+ — v\d+\.\d+\.\d+", head):
    errors.append(f"AGENT-STANDARD.md: first line is not a '# <title> — vX.Y.Z' header: {head!r}")

agents = ROOT / "AGENTS.md"
if len(agents.read_text().splitlines()) > 90:
    errors.append("AGENTS.md exceeds 90 lines")

for md in sorted(ROOT.rglob("*.md")):
    if ".git" in md.relative_to(ROOT).parts or ".worktrees" in md.relative_to(ROOT).parts:
        continue
    fence = None  # (char, length) of the open fence
    for n, line in enumerate(md.read_text().splitlines(), 1):
        m = FENCE.match(line)
        if fence:
            if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= fence[1] and not m.group(2).strip():
                fence = None
            continue
        if m and not (m.group(1)[0] == "`" and "`" in m.group(2)):
            fence = (m.group(1)[0], len(m.group(1)))
            continue
        ref = REFDEF.match(line)
        for target in ([ref.group(1)] if ref else []) + LINK.findall(line):
            if re.match(r"[a-z][a-z0-9+.-]*:", target) or target.startswith("#"):
                continue
            if target.startswith("/"):
                errors.append(f"{md.relative_to(ROOT)}:{n}: absolute link {target} (not repo-relative)")
            elif not (md.parent / target.split("#")[0]).resolve().exists():
                errors.append(f"{md.relative_to(ROOT)}:{n}: broken link {target}")

for e in errors:
    print(e, file=sys.stderr)
print(f"check-docs: {'FAIL' if errors else 'ok'} ({len(errors)} problems)")
sys.exit(1 if errors else 0)
