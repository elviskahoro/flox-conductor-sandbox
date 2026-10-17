"""Lint the canonical conductor prompts for dangling colon paragraphs."""

from pathlib import Path

import pytest

PROMPTS = sorted((Path(__file__).resolve().parent.parent / "prompts" / "conductor").glob("*.md"))


def dangling_colons(text: str) -> list[int]:
    """Return 1-based line numbers of lines ending in ':' whose next non-blank
    line is not a fence, list item, table row, quote, or indented block."""
    lines = text.split("\n")
    bad = []
    in_fence = False
    for i, line in enumerate(lines):
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence or not line.rstrip().endswith(":") or not line.strip():
            continue
        nxt = next((l for l in lines[i + 1 :] if l.strip()), "")
        if not nxt.lstrip().startswith(("```", "-", "*", "|", "1.", "> ", "    ")):
            bad.append(i + 1)
    return bad


@pytest.mark.parametrize("path", PROMPTS, ids=lambda p: p.name)
def test_no_dangling_colon(path):
    assert dangling_colons(path.read_text()) == []


def test_detects_dangling_colon():
    assert dangling_colons("Run this:\n\n\nNext paragraph.\n") == [1]
    assert dangling_colons("Run this:\n\n```bash\nx\n```\n") == []
    assert dangling_colons("Items:\n- a\n") == []
