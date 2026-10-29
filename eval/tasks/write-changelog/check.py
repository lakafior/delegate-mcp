"""setup: builds the git history (tag v1.2.0, then 20 commits). check: the 1.3.0 section lists the user-facing
changes after the tag and none of the technical or older ones."""
import json
import re
import subprocess
from pathlib import Path

HERE = Path(__file__).parent
WANTED = {"markdown tables": r"table", "pdf export": r"pdf", "tag colors": r"colou?r", "multi-tag filter": r"(several|multiple) tags",
          "default font": r"font", "faster index": r"(faster|index)", "sync conflicts": r"conflict", "empty note crash": r"crash",
          "diacritics": r"diacritic", "pdf images": r"(image|aspect)", "retry after wake": r"(wake|sleep)", "evernote removed": r"evernote"}
UNWANTED = {"deps bump": r"swift-markdown|bump", "ci": r"swiftpm|ui tests|\bci\b", "refactor": r"syncengine|refactor",
            "format": r"swift-format", "typo": r"typo|contributing", "older dark mode": r"dark mode"}


def setup(workdir):
    history = json.loads((HERE / "history.json").read_text())
    git = lambda *a: subprocess.run(["git", *a], cwd=workdir, check=True, capture_output=True)
    who = ["-c", "user.name=Ola Kowalska", "-c", "user.email=ola@example.com"]
    git("init", "-q")
    git("add", "-A")
    git(*who, "commit", "-q", "-m", "Initial import")
    files = sorted(p.name for p in (workdir / "src").iterdir())
    for i, message in enumerate(history["before_tag"] + history["after_tag"]):
        target = workdir / "src" / files[i % len(files)]
        target.write_text(target.read_text() + f"// {message}\n")
        git("add", "-A")
        git(*who, "commit", "-q", "-m", message)
        if i == len(history["before_tag"]) - 1:
            git("tag", "v1.2.0")


def check(workdir):
    text = (workdir / "CHANGELOG.md").read_text()
    match = re.search(r"## \[?1\.3\.0\]?(.*?)(?=\n## \[?1\.2\.0)", text, re.S)
    if not match:
        return {"score": 0.0, "notes": "no 1.3.0 section above 1.2.0"}
    section = match.group(1).lower()
    have = [k for k, p in WANTED.items() if re.search(p, section)]
    leaked = [k for k, p in UNWANTED.items() if re.search(p, section)]
    old_intact = "Dark mode that follows the system appearance." in text
    score = max(0.0, len(have) / len(WANTED) - 0.1 * len(leaked)) * (1.0 if old_intact else 0.5)
    return {"score": round(score, 3), "notes": f"user-facing {len(have)}/{len(WANTED)}, leaked {leaked or 'none'}, "
                                               f"1.2.0 intact {old_intact}"}
