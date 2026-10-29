"""USAGE.md mentions every option and subcommand that tidy.py defines."""
import re


def check(workdir):
    source = (workdir / "tidy.py").read_text()
    try:
        doc = (workdir / "docs/USAGE.md").read_text()
    except FileNotFoundError:
        return {"score": 0.0, "notes": "docs/USAGE.md missing"}
    options = set(re.findall(r"""["'](--[a-z][a-z0-9-]*)["']""", source))
    commands = set(re.findall(r"""add_parser\(\s*["']([a-z-]+)["']""", source))
    wanted = options | commands
    if not wanted:
        return {"score": 0.0, "notes": "no options found in tidy.py (check the parser)"}
    missing = sorted(w for w in wanted if w not in doc)
    return {"score": round(1 - len(missing) / len(wanted), 3),
            "notes": f"{len(wanted)} options/commands, missing: {', '.join(missing) or 'none'}"}
