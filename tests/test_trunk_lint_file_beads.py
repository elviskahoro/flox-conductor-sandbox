import importlib.util
import sys
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "trunk_lint_file_beads",
    Path(__file__).resolve().parent.parent / "scripts" / "trunk-lint-file-beads.py",
)
mod = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = mod
_spec.loader.exec_module(mod)

REPORT = """\x1b[1mfoo/a.py:3:1\x1b[0m
 3:1  high  F401  unused import
 9:5  low   E501  line too long

foo/b.md
 0:0  low   Incorrect formatting

foo/a.py:20:1
 20:1  low  E302  expected 2 blank lines

Checked 3 files
"""


def test_groups_by_file_and_merges_repeats():
    found = {f.path: f for f in mod.parse_findings_by_file(REPORT)}
    assert list(found) == ["foo/a.py", "foo/b.md"]
    assert found["foo/a.py"].issue_count == 3
    assert found["foo/b.md"].issue_count == 1
    assert "Checked 3 files" not in found["foo/a.py"].block


def test_bare_banner_is_not_a_header():
    assert "Checked 3 files" not in {f.path for f in mod.parse_findings_by_file(REPORT)}


def test_title_pluralises():
    f = mod.FileFindings(path="x.py", block="", issue_count=1)
    assert mod.bead_title(f) == "trunk lint: 1 issue in x.py"


def test_parse_created_id_rejects_garbage():
    import pytest

    with pytest.raises(mod.BdListParseError):
        mod.parse_created_id("nope")
    assert mod.parse_created_id('{"id": "b-1"}') == "b-1"
