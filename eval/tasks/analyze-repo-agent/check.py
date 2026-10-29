"""Like analyze-repo (the snapshot and the expected places are the same)."""
import importlib.util
from pathlib import Path

_spec = importlib.util.spec_from_file_location("analyze", Path(__file__).parent.parent / "analyze-repo/check.py")
_base = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_base)
setup = _base.setup
check = _base.check
