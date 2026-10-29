"""setup: generates logs/server.log (make_log.py, deterministic; *.log is git-ignored). check: INCIDENTS.md names
the three incidents hidden in the log and the OOM recurrence."""
import re
import subprocess
from pathlib import Path

FACTS = {
    "db pool exhausted": [r"(pool|połącze|connection)", r"(nightly-export|export)"],
    "payments certificate expired": [r"(certyfikat|certificate|tls)", r"(payments|płatno)", r"0?8:4[67]"],
    "worker-3 OOM": [r"worker-3", r"(oom|out of memory|pamię|memory)"],
    "OOM repeats 3x": [r"(04:10|4:10)", r"11:25", r"18:40"],
}


def setup(workdir):
    subprocess.run(["python3", "-I", str(Path(__file__).parent / "make_log.py"), str(workdir / "logs/server.log")],
                   check=True, capture_output=True)
    git = lambda *a: subprocess.run(["git", *a], cwd=workdir, check=True, capture_output=True)
    git("init", "-q")
    git("add", "-A")
    git("-c", "user.name=eval", "-c", "user.email=eval@example.com", "commit", "-q", "-m", "input")


def check(workdir):
    try:
        text = (workdir / "INCIDENTS.md").read_text().lower()
    except FileNotFoundError:
        return {"score": 0.0, "notes": "INCIDENTS.md missing"}
    found = [name for name, patterns in FACTS.items() if all(re.search(p, text) for p in patterns)]
    return {"score": len(found) / len(FACTS), "notes": f"found {len(found)}/{len(FACTS)}: {', '.join(found) or 'none'}"}
