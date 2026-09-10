#!/usr/bin/env python3
from __future__ import annotations
import re
import sys
from pathlib import Path
import yaml

ROOT = Path(__file__).resolve().parents[1]
SKILL = ROOT / "SKILL.md"


def main() -> int:
    text = SKILL.read_text(encoding="utf-8")
    errors = []
    warnings = []
    if not text.startswith("---\n"):
        errors.append("SKILL.md must begin with YAML frontmatter")
        front = {}
        body = text
    else:
        parts = text.split("---\n", 2)
        if len(parts) < 3:
            errors.append("Could not parse YAML frontmatter")
            front, body = {}, text
        else:
            front = yaml.safe_load(parts[1]) or {}
            body = parts[2]

    name = front.get("name")
    desc = front.get("description")
    if not isinstance(name, str):
        errors.append("name is required")
    else:
        if len(name) > 64 or not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", name):
            errors.append("name violates Agent Skills naming constraints")
        if name != ROOT.name:
            errors.append(f"name '{name}' must match parent directory '{ROOT.name}'")
    if not isinstance(desc, str) or not desc.strip():
        errors.append("description is required and non-empty")
    elif len(desc) > 1024:
        errors.append("description exceeds 1024 characters")

    lines = len(text.splitlines())
    if lines >= 500:
        errors.append(f"SKILL.md has {lines} lines; keep under 500")

    # A conservative rough estimate. Claude tokenization differs; this is a guardrail, not a tokenizer.
    rough_tokens = round(len(body.split()) * 1.35)
    if rough_tokens >= 5000:
        warnings.append(f"rough token estimate {rough_tokens} may exceed 5000-token recommendation")

    refs = re.findall(r"\]\((references/[^)]+)\)", body)
    for ref in refs:
        p = ROOT / ref
        if not p.exists():
            errors.append(f"missing referenced file: {ref}")
        if Path(ref).parent != Path("references"):
            warnings.append(f"deep reference chain/path: {ref}")

    print(f"name={name}")
    print(f"description_chars={len(desc) if isinstance(desc,str) else 0}")
    print(f"lines={lines}")
    print(f"rough_instruction_tokens={rough_tokens}")
    print(f"references_checked={len(refs)}")
    for w in warnings:
        print(f"WARNING: {w}")
    for e in errors:
        print(f"ERROR: {e}")
    if errors:
        return 1
    print("VALID: local structural checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
