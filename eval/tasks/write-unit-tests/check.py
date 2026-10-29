"""Tests pass on the real module and fail on mutants (each mutant breaks one documented behaviour)."""
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

MUTANTS = {
    "slugify drops ł mapping": ("without_accents = without_accents.replace('ł', 'l').replace('Ł', 'L')", "pass"),
    "truncate ignores placeholder width": ("text.rfind(' ', 0, truncate_len)", "text.rfind(' ', 0, width)"),
    "parse_duration allows repeated units": ("if unit in seen_units:", "if False:"),
    "format_bytes binary uses 1000": ("divisor = 1024", "divisor = 1000"),
    "word_wrap rejects exact fit": ("if current_length + len(current_line) + word_length <= width:",
                                    "if current_length + len(current_line) + word_length < width:"),
}


def run_tests(root):
    root = Path(root).resolve()
    env = dict(os.environ, PYTHONPATH=f"{root}/src:{root}")
    try:
        proc = subprocess.run(["python3", "-m", "unittest", "discover", "-s", "tests"], cwd=root, env=env,
                              capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        return False, "timeout"
    return proc.returncode == 0, (proc.stderr.strip().splitlines() or [""])[-1]


def check(workdir):
    if not (workdir / "tests/test_textutils.py").exists():
        return {"score": 0.0, "notes": "tests/test_textutils.py missing"}
    ok, summary = run_tests(workdir)
    if not ok:
        return {"score": 0.0, "notes": f"tests fail on the real module: {summary}"}
    source = (workdir / "src/textutils.py").read_text()
    killed = []
    for name, (old, new) in MUTANTS.items():
        assert old in source, name
        with tempfile.TemporaryDirectory() as tmp:
            copy = Path(tmp) / "repo"
            shutil.copytree(workdir, copy, ignore=shutil.ignore_patterns(".git", "__pycache__"))
            (copy / "src/textutils.py").write_text(source.replace(old, new, 1))
            if not run_tests(copy)[0]:
                killed.append(name)
    return {"score": len(killed) / len(MUTANTS),
            "notes": f"{summary}; mutants killed {len(killed)}/{len(MUTANTS)}; survived: "
                     f"{', '.join(n for n in MUTANTS if n not in killed) or 'none'}"}
