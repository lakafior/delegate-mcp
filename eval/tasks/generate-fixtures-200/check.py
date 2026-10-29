"""Like generate-fixtures, with 200 orders."""
import importlib.util
from pathlib import Path

_spec = importlib.util.spec_from_file_location("fixtures25", Path(__file__).parent.parent / "generate-fixtures/check.py")
_base = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_base)


def check(workdir):
    return _base.check(workdir, expected=200)
