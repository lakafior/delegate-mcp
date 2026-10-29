"""setup: exports the delegate-mcp repo at a fixed commit. check: ANALYSIS.md names the right places."""
import re
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
COMMIT = "8989842"
PLACES = {"enum in RoutingPolicy.swift": r"routingpolicy\.swift", "routingPlan in DelegateService.swift": r"delegateservice\.swift",
          "refusalAdvice": r"refusaladvice", "GUI RoutingView.swift": r"routingview\.swift", "tests": r"refusaladvicetests|test"}


def setup(workdir):
    archive = subprocess.run(["git", "-C", str(REPO), "archive", COMMIT, "Sources", "Tests", "Package.swift", "CLAUDE.md"],
                             check=True, capture_output=True).stdout
    subprocess.run(["tar", "-x", "-C", str(workdir)], input=archive, check=True)
    (workdir / ".keep").unlink(missing_ok=True)
    git = lambda *a: subprocess.run(["git", *a], cwd=workdir, check=True, capture_output=True)
    git("init", "-q")
    git("add", "-A")
    git("-c", "user.name=eval", "-c", "user.email=eval@example.com", "commit", "-q", "-m", f"delegate-mcp at {COMMIT}")


def check(workdir):
    try:
        text = (workdir / "ANALYSIS.md").read_text().lower()
    except FileNotFoundError:
        return {"score": 0.0, "notes": "ANALYSIS.md missing"}
    found = [k for k, p in PLACES.items() if re.search(p, text)]
    changed = subprocess.run(["git", "status", "--porcelain", "--", "Sources"], cwd=workdir, capture_output=True, text=True).stdout
    score = len(found) / len(PLACES) * (0.5 if changed.strip() else 1.0)
    return {"score": round(score, 3), "notes": f"places {len(found)}/{len(PLACES)} ({', '.join(found)}), code changed: {bool(changed.strip())}"}
