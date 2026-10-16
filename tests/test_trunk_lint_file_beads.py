import importlib.util
import sys
from pathlib import Path

from typer.testing import CliRunner

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
    found = {f.path: f for f in mod.parse_findings_by_file(REPORT).findings}
    assert list(found) == ["foo/a.py", "foo/b.md"]
    assert found["foo/a.py"].issue_count == 3
    assert found["foo/b.md"].issue_count == 1
    assert "Checked 3 files" not in found["foo/a.py"].block


def test_bare_banner_is_not_a_header():
    assert "Checked 3 files" not in {f.path for f in mod.parse_findings_by_file(REPORT).findings}


def test_title_pluralises():
    f = mod.FileFindings(path="x.py", block="", issue_count=1)
    assert mod.bead_title(f) == "trunk lint: 1 issue in x.py"


def test_parse_created_id_rejects_garbage():
    import pytest

    with pytest.raises(mod.BdListParseError):
        mod.parse_created_id("nope")
    assert mod.parse_created_id('{"id": "b-1"}') == "b-1"


def test_flush_left_continuation_stays_in_block():
    rep = "a.py:1:1\n 1:1  low  X  msg\n@@ -1 +1 @@\n 2:1  low  Y  msg2\n\nChecked 1 file\n"
    (f,) = mod.parse_findings_by_file(rep).findings
    assert f.issue_count == 2
    assert "@@ -1 +1 @@" in f.block
    assert "Checked" not in f.block


def test_footer_after_bare_path_block():
    rep = "b.md\n 0:0  low  fmt  Incorrect formatting\n\nChecked 1 file\n"
    (f,) = mod.parse_findings_by_file(rep).findings
    assert "Checked" not in f.block


def test_linter_failure_regex():
    assert mod._LINTER_FAILURE_RE.search("Linter foo failed to install")


def test_bare_count_footer_and_blank_then_flush_left():
    rep = "a.py:1:1\n 1:1  low  X  msg\n\n3 issues\n"
    (f,) = mod.parse_findings_by_file(rep).findings
    assert "3 issues" not in f.block
    rep2 = "a.py:1:1\n 1:1  low  X  msg\n\nsome trailer\n"
    (g,) = mod.parse_findings_by_file(rep2).findings
    assert "trailer" not in g.block


def test_linter_failure_ignores_indented_finding_text():
    out = "a.py:1:1\n 1:1  low  X  trunk check failed to run\n"
    assert not mod._LINTER_FAILURE_RE.search(mod._unindented_lines(out))
    assert mod._LINTER_FAILURE_RE.search(mod._unindented_lines("Linter foo failed to install\n"))


def test_dropped_rows_reported_after_footer():
    rep = "a.py:1:1\n 1:1  low  X  m\n\nChecked 1 file\n 2:1  low  Y  m2\n"
    assert mod.parse_findings_by_file(rep).dropped_rows == ["2:1  low  Y  m2"]
    assert mod.parse_findings_by_file(REPORT).dropped_rows == []


def _run_prune(monkeypatch, tmp_path, rep, stderr=""):
    monkeypatch.setattr(
        mod,
        "run_trunk_check",
        lambda *, fix: mod.TrunkRunResult(output=rep, stderr=stderr, return_code=1),
    )
    monkeypatch.setattr(mod, "list_existing_beads", lambda: {"gone.py": "b-1"})
    monkeypatch.setattr(mod, "find_or_create_epic", lambda *, dry_run: "e-1")
    monkeypatch.setattr(mod, "upsert_bead", lambda *a, **k: "ok")
    closed = []

    def fake_close(existing, **kwargs):
        closed.append((existing, kwargs))
        return []

    monkeypatch.setattr(mod, "close_stale_beads", fake_close)
    report = str(tmp_path / "report.txt")
    res = CliRunner().invoke(mod.app, ["--prune-resolved", "--report", report])
    return res, closed


def test_prune_skipped_with_exit_3(monkeypatch, tmp_path):
    rep = "a.py:1:1\n 1:1  low  X  m\n\nChecked 1 file\n 2:1  low  Y  m2\n"
    res, closed = _run_prune(monkeypatch, tmp_path, rep)
    assert res.exit_code == 3
    assert "dropped orphan issue row" in res.output
    assert "skipping --prune-resolved" in res.output
    assert not closed


def test_prune_runs_on_clean_parse(monkeypatch, tmp_path):
    rep = "a.py:1:1\n 1:1  low  X  m\n\nChecked 1 file\n"
    res, closed = _run_prune(monkeypatch, tmp_path, rep)
    assert res.exit_code == 0
    assert "dropped" not in res.output
    assert len(closed) == 1
    assert closed[0][0] == {"gone.py": "b-1"}
    assert closed[0][1]["current_paths"] == {"a.py"}
    assert closed[0][1]["dry_run"] is False


def test_prune_skipped_on_ansi_linter_failure(monkeypatch, tmp_path):
    rep = "a.py:1:1\n 1:1  low  X  m\n\nChecked 1 file\n"
    res, closed = _run_prune(
        monkeypatch, tmp_path, rep, stderr="\x1b[31mLinter foo failed to run\x1b[0m"
    )
    assert res.exit_code == 3
    assert "skipping --prune-resolved" in res.output
    assert not closed
