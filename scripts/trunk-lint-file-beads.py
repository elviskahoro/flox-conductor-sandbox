#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["typer"]
# ///
# ruff: noqa: N999
"""Run `trunk check --all --show-existing` and file one bead per offending file.

Trunk's own output is the single source of truth: this script does not
re-implement any linter's rule set. It only (1) runs the check, (2) groups
the plain-text report by file path, and (3) upserts one bead per path so a
sweep-style cleanup ("fix the lint in file X") has a natural work unit.

The full raw trunk report is always written to one file
(`tmp/trunk-lint-report.txt` by default) -- that is the "one file has all the
issues" artifact everything else is derived from. Each created bead's
description is the excerpt for that path plus a pointer back to the report
file, so a bead never goes stale relative to trunk's own formatting.

`trunk` and `bd` run on the host, from the repo root (this repo's Flox
environment should already be active).

`--fix` is opt-in, not the default: a bead-filing sweep is meant to be a
read-and-classify operation, and auto-mutating the working tree on every run
(especially under a schedule/cron) is a surprise an operator should choose,
not inherit.

Re-running is safe: each bead is tagged with the `trunk-lint` label and a
`trunk_file` metadata key equal to the path, so an existing open bead for a
path is updated (title/description refreshed) instead of duplicated.

`--prune-resolved` is opt-in, not the default: a path that no longer appears
in the report (because it was fixed, or the offending file was removed) can
have its bead closed automatically, but only when the underlying `trunk
check` run completed cleanly (exit 0 or 1) -- any other exit code aborts
before touching beads at all, since the captured output can't be trusted as a
complete report. This is opt-in because a partial trunk run (a linter that failed to
install, or a transient parse gap) would
otherwise look identical to "these files are fixed" and silently close beads
for issues that never went away.

Usage:
    scripts/trunk-lint-file-beads.py
    scripts/trunk-lint-file-beads.py --fix
    scripts/trunk-lint-file-beads.py --prune-resolved
    scripts/trunk-lint-file-beads.py --dry-run
    scripts/trunk-lint-file-beads.py --report tmp/trunk-lint-report.txt
"""

from __future__ import annotations

import json
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

import typer

REPO_ROOT = Path(__file__).resolve().parent.parent


class BdCommandError(RuntimeError):
    """A `bd` invocation exited non-zero."""

    def __init__(self, argv: list[str], exc: subprocess.CalledProcessError) -> None:
        self.argv = argv
        self.stderr = (exc.stderr or "").strip()
        super().__init__(f"bd {' '.join(argv)} failed: {self.stderr}")


def run_bd(argv: list[str], *, cwd: Path) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(  # noqa: S603
            ["bd", *argv],  # noqa: S607
            cwd=cwd,
            capture_output=True,
            text=True,
            check=True,
        )
    except subprocess.CalledProcessError as exc:
        raise BdCommandError(argv, exc) from exc


def report_bd_failure(exc: BdCommandError) -> None:
    typer.echo(f"error: {exc}", err=True)


def trunk_args(*, fix: bool) -> list[str]:
    args = ["trunk", "check", "--all", "--show-existing", "--no-progress"]
    if fix:
        args.insert(2, "--fix")
    return args


DEFAULT_REPORT_PATH = REPO_ROOT / "tmp" / "trunk-lint-report.txt"

BEAD_LABEL = "trunk-lint"
METADATA_KEY = "trunk_file"

EPIC_LABEL = "trunk-lint-epic"
EPIC_METADATA_KEY = "trunk_lint_epic"
EPIC_METADATA_VALUE = "sweep"
EPIC_TITLE = "[epic] trunk lint: sweep cleanup"

# Matches a flush-left "<path>" or "<path>:<line>:<col>" header line -- the
# table rows underneath it are always indented, so this never mistakes an
# issue row or a code-snippet line for a new file's header. Verified against
# real `trunk check` output: most findings render "<path>:<line>:<col>", but
# whole-file findings (e.g. a formatter's "Incorrect formatting") render only
# the bare path with no line:col suffix. The line:col group is therefore
# optional; parse_findings_by_file below only treats a bare-path match as an
# actual header when the next non-blank line looks like an issue row, so a
# summary/banner line that happens to have no leading whitespace (e.g.
# "Checked 1 file") is never mistaken for one.
_FILE_HEADER_RE = re.compile(r"^(?P<path>\S+?)(?::(?P<line>\d+):(?P<col>\d+))?\s*$")

# Matches an issue row's own leading "<line>:<col>  <severity>" columns, used
# both to confirm a bare-path header candidate and to produce a
# human-friendly count in the bead title.
_ISSUE_ROW_RE = re.compile(r"^\s*\d+:\d+\s+(low|medium|high|critical)\s", re.IGNORECASE)

_ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


class TrunkCommandError(RuntimeError):
    """`trunk check` could not be run at all (missing binary, transport failure)."""


@dataclass
class FileFindings:
    path: str
    block: str
    issue_count: int


def strip_ansi(text: str) -> str:
    """Drop color/cursor-control escapes so the header regex sees plain text."""
    return _ANSI_RE.sub("", text)


# `trunk check` exits 0 (clean) or 1 (issues found, --show-existing) for a
# completed run; any other code means the invocation itself misbehaved
# (crash, bad args, transport failure), so its output is not a trustworthy
# full report and must not drive bead reconciliation.
_CLEAN_RUN_RETURN_CODES = (0, 1)


@dataclass
class TrunkRunResult:
    output: str  # stdout only: the parseable report
    stderr: str
    return_code: int | None  # None when the transport can't surface an exit code


def run_trunk_check(*, fix: bool) -> TrunkRunResult:
    """Run the trunk check and return its combined stdout+stderr as plain text.

    `trunk check` exits non-zero whenever it finds unresolved issues -- that
    is the expected, common case here, not a transport failure -- so this
    only raises when the *invocation itself* could not complete. The exit
    code is carried alongside the output so callers can tell a completed run
    (0 or 1) from a crash that happened to print something on stderr.
    """
    try:
        proc = subprocess.run(  # noqa: S603
            trunk_args(fix=fix),
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError as exc:
        msg = f"trunk check failed to run: {exc}"
        raise TrunkCommandError(msg) from exc
    return TrunkRunResult(
        output=proc.stdout or "",
        stderr=proc.stderr or "",
        return_code=proc.returncode,
    )


def _next_nonblank(lines: list[str], start: int) -> str | None:
    for candidate in lines[start:]:
        if candidate.strip():
            return candidate
    return None


def parse_findings_by_file(raw_output: str) -> list[FileFindings]:
    """Group trunk's report into one block of text per distinct file path.

    A header line ("<path>:<line>:<col>" or bare "<path>", flush left) can
    recur for the same path across different report sections (e.g. autofix
    suggestions followed by a plain issue table); every occurrence is
    appended to that path's running block, in the order trunk printed it, so
    nothing is dropped.

    A header with an explicit "<line>:<col>" is trusted on sight. A bare
    "<path>" (no line:col -- real for whole-file findings like a formatter's
    "Incorrect formatting") is only trusted as a header when the next
    non-blank line looks like an issue row, so a flush-left summary/banner
    line (e.g. "Checked 1 file") is never mistaken for a new file.
    """
    text = strip_ansi(raw_output)
    lines = text.splitlines()
    blocks: dict[str, list[str]] = {}
    order: list[str] = []
    current_path: str | None = None
    current_lines: list[str] = []

    def flush() -> None:
        if current_path is None:
            return
        blocks.setdefault(current_path, [])
        if current_path not in order:
            order.append(current_path)
        blocks[current_path].append("\n".join(current_lines).rstrip())

    for index, line in enumerate(lines):
        header = _FILE_HEADER_RE.match(line)
        has_line_col = header is not None and header.group("line") is not None
        is_header = has_line_col or (
            header is not None
            and (nxt := _next_nonblank(lines, index + 1)) is not None
            and _ISSUE_ROW_RE.match(nxt) is not None
        )
        if is_header:
            assert header is not None  # noqa: S101 -- is_header implies a match above
            flush()
            current_path = header.group("path")
            current_lines = [line]
        elif current_path is not None:
            current_lines.append(line)
    flush()

    findings = []
    for path in order:
        block = "\n\n".join(part for part in blocks[path] if part)
        issue_count = sum(1 for line in block.splitlines() if _ISSUE_ROW_RE.match(line))
        findings.append(
            FileFindings(path=path, block=block, issue_count=max(issue_count, 1)),
        )
    return findings


class BdListParseError(RuntimeError):
    """`bd list --json` returned output that could not be parsed as JSON."""


def list_existing_beads() -> dict[str, str]:
    """Return {path: bead_id} for every open trunk-lint bead.

    Fetched once per run so both the per-file upsert and the stale-bead
    reconciliation pass work off the same snapshot. The script's "re-running
    is safe, beads are updated not duplicated" contract depends on this
    lookup actually finding existing beads, so a parse failure must not
    silently fall back to "no existing beads" -- that would look like a
    clean idempotent re-run while actually duplicating every bead. Raising
    lets the caller abort instead.
    """
    result = run_bd(["list", "--label", BEAD_LABEL, "--limit", "0", "--json"], cwd=REPO_ROOT)
    stdout = result.stdout.strip() if result.stdout else ""
    try:
        # An empty stdout is treated as "no beads" only when it is truly
        # empty; anything else must parse to a JSON list, otherwise a
        # truncated/garbled-but-non-empty response would silently look like
        # a fresh state and duplicate every bead on this run.
        issues = json.loads(stdout) if stdout else []
    except json.JSONDecodeError as exc:
        msg = f"bd list --json returned unparseable output: {exc}"
        raise BdListParseError(msg) from exc
    if not isinstance(issues, list):
        msg = f"bd list --json returned a JSON {type(issues).__name__}, expected a list"
        raise BdListParseError(msg)
    beads: dict[str, str] = {}
    for issue in issues:
        if not isinstance(issue, dict):
            msg = f"bd list --json returned a non-object entry: {issue!r}"
            raise BdListParseError(msg)
        metadata = issue.get("metadata")
        if metadata is not None and not isinstance(metadata, dict):
            msg = f"bd list --json entry has non-object metadata: {metadata!r}"
            raise BdListParseError(msg)
        path = metadata.get(METADATA_KEY) if metadata else None
        bead_id = issue.get("id")
        if path and bead_id:
            beads[path] = bead_id
    return beads


def _list_epic_candidates() -> list[dict[str, object]]:
    """Return every open bead matching the sweep epic's type/label/metadata.

    Filtering on ``--type epic`` (not just the label/metadata pair) means a
    malformed or manually created non-epic bead that happens to carry the
    same label and metadata is never mistaken for the sweep epic.
    """
    result = run_bd(
        [
            "list",
            "--type",
            "epic",
            "--label",
            EPIC_LABEL,
            "--metadata-field",
            f"{EPIC_METADATA_KEY}={EPIC_METADATA_VALUE}",
            "--limit",
            "0",
            "--json",
        ],
        cwd=REPO_ROOT,
    )
    stdout = result.stdout.strip() if result.stdout else ""
    try:
        issues = json.loads(stdout) if stdout else []
    except json.JSONDecodeError as exc:
        msg = f"bd list --json returned unparseable output: {exc}"
        raise BdListParseError(msg) from exc
    if not isinstance(issues, list):
        msg = f"bd list --json returned a JSON {type(issues).__name__}, expected a list"
        raise BdListParseError(msg)
    for issue in issues:
        if not isinstance(issue, dict):
            msg = f"bd list --json returned a non-object entry: {issue!r}"
            raise BdListParseError(msg)
        epic_id = issue.get("id")
        if not epic_id or not isinstance(epic_id, str):
            msg = f"bd list --json returned an entry with no usable id: {issue!r}"
            raise BdListParseError(msg)
    return issues


def _lowest_epic_id(candidates: list[dict[str, object]]) -> str:
    """Deterministically pick one epic id from every matching candidate.

    ``_list_epic_candidates`` already guarantees every entry has a non-empty
    string id, so this never raises -- it's kept separate so the "which one
    wins" tie-break logic has one place to live.
    """
    return min(str(issue["id"]) for issue in candidates)


def find_or_create_epic(*, dry_run: bool) -> str:
    """Find the sweep epic every file-bead should be parented under, or create it.

    Mirrors ``list_existing_beads``'s defensiveness: a non-empty response
    that fails to parse as a JSON list of objects must abort rather than be
    treated as "no epic yet", since that would silently spawn a duplicate
    epic on every run instead of reusing the one true sweep epic.

    ``bd`` has no create-if-not-exists primitive, so two concurrent sweep
    runs can both see "no epic yet" and each create one. Rather than assume
    that never happens, re-list after creating and deterministically settle
    on the lowest id among every matching epic (including the one just
    created), so two callers that both survive to the re-list step converge
    on the same winner without needing a lock. This narrows, but does not
    close, the race: two runs whose creates *and* re-lists both land before
    either write is visible to the other can still each pick their own epic.
    ``bd`` exposes no repository-level lock to close that window, and this
    script is a manual/cron sweep tool that is not expected to run
    concurrently with itself in practice, so the residual risk is accepted
    rather than engineered away. A loser epic is left open rather than
    auto-closed here; reconciling it is the same deliberate manual step the
    module docstring already carves out for ``--prune-resolved``.
    """
    candidates = _list_epic_candidates()
    if candidates:
        epic_id = _lowest_epic_id(candidates)
        typer.echo(f"→ reusing epic {epic_id}: {EPIC_TITLE}")
        return epic_id

    if dry_run:
        typer.echo(f"→ would create epic: {EPIC_TITLE}")
        return "<new-epic>"

    result = run_bd(
        [
            "create",
            "--title",
            EPIC_TITLE,
            "--labels",
            EPIC_LABEL,
            "--type",
            "epic",
            "--metadata",
            json.dumps({EPIC_METADATA_KEY: EPIC_METADATA_VALUE}),
            "--json",
        ],
        cwd=REPO_ROOT,
    )
    created_id = parse_created_id(result.stdout)

    # Re-list to catch a sibling process that created a competing epic
    # between this call's initial lookup and its own create above.
    settled_id = _lowest_epic_id(_list_epic_candidates())
    if settled_id != created_id:
        typer.echo(
            f"→ created epic {created_id} but {settled_id} won the race, using it",
        )
        return settled_id
    typer.echo(f"→ created epic {created_id}: {EPIC_TITLE}")
    return created_id


def parse_created_id(stdout: str) -> str:
    try:
        created = json.loads(stdout)
        return str(created["id"])
    except (json.JSONDecodeError, KeyError, TypeError) as exc:
        msg = f"bd create --json returned no usable id: {stdout[:200]!r}"
        raise BdListParseError(msg) from exc


def bead_title(finding: FileFindings) -> str:
    plural = "" if finding.issue_count == 1 else "s"
    return f"trunk lint: {finding.issue_count} issue{plural} in {finding.path}"


MAX_BLOCK_CHARS = 20_000


def bead_description(finding: FileFindings, *, report_path: Path) -> str:
    block = finding.block
    if len(block) > MAX_BLOCK_CHARS:
        block = block[:MAX_BLOCK_CHARS] + "\n... (truncated; see full report)"
    return (
        f"`trunk check --all --show-existing` findings for `{finding.path}`.\n"
        f"Full report: {report_path}\n\n"
        "```\n"
        f"{block}\n"
        "```\n"
    )


def upsert_bead(
    finding: FileFindings,
    *,
    report_path: Path,
    existing_beads: dict[str, str],
    epic_id: str | None,
    dry_run: bool,
) -> str:
    title = bead_title(finding)
    description = bead_description(finding, report_path=report_path)
    existing_id = existing_beads.get(finding.path)

    if dry_run:
        verb = "would update" if existing_id else "would create"
        return f"{verb} {existing_id or '<new>'}: {title}"

    if existing_id:
        # --metadata is deliberately not re-sent here: existing_id was looked
        # up via list_existing_beads() keyed on this exact METADATA_KEY/path
        # pair, so an update can never change it. Only a future migration of
        # the metadata scheme itself (e.g. absolute -> relative paths) would
        # need this refreshed, and that would touch every bead at once, not
        # one at a time through this per-file upsert.
        run_bd(
            [
                "update",
                existing_id,
                "--title",
                title,
                "--description",
                description,
            ],
            cwd=REPO_ROOT,
        )
        return f"updated {existing_id}: {title}"

    # Reaching here (not dry-run, no existing bead) means a new bead is
    # about to be created, and the caller only omits epic_id when it already
    # knows every finding matches an existing bead -- so a create-path call
    # always carries a real epic id.
    assert epic_id is not None, "epic_id must be set before creating a new bead"  # noqa: S101
    result = run_bd(
        [
            "create",
            "--title",
            title,
            "--description",
            description,
            "--labels",
            BEAD_LABEL,
            "--type",
            "task",
            "--metadata",
            json.dumps({METADATA_KEY: finding.path}),
            "--parent",
            epic_id,
            "--json",
        ],
        cwd=REPO_ROOT,
    )
    return f"created {parse_created_id(result.stdout)}: {title}"


def close_stale_beads(
    existing_beads: dict[str, str],
    *,
    current_paths: set[str],
    dry_run: bool,
) -> list[str]:
    """Close beads for files no longer present in the current trunk report."""
    summaries = []
    for path, bead_id in existing_beads.items():
        if path in current_paths:
            continue
        if dry_run:
            summaries.append(f"would close {bead_id}: {path} (resolved)")
            continue
        run_bd(["close", bead_id, "--reason", "resolved"], cwd=REPO_ROOT)
        summaries.append(f"closed {bead_id}: {path} (resolved)")
    return summaries


app = typer.Typer(
    add_completion=False,
    help=__doc__,
)


@app.command()
def main(
    report: Path = typer.Option(
        DEFAULT_REPORT_PATH,
        "--report",
        help="Where to write the full raw trunk report (the 'one file has all the issues' artifact).",
    ),
    dry_run: bool = typer.Option(  # noqa: FBT001
        default=False,
        help="Show what would be created/updated without writing to beads.",
    ),
    fix: bool = typer.Option(  # noqa: FBT001
        default=False,
        help="Pass --fix to trunk, auto-applying its fixes before filing beads "
        "for residual issues. Off by default so a bead-filing sweep never "
        "mutates the working tree unless explicitly asked to.",
    ),
    prune_resolved: bool = typer.Option(  # noqa: FBT001
        default=False,
        help="Close trunk-lint beads for paths no longer in the report. Off "
        "by default -- see the module docstring for why an unconditional "
        "prune is unsafe.",
    ),
) -> None:
    if dry_run and fix:
        typer.echo("error: --dry-run cannot be combined with --fix (trunk would mutate the tree)", err=True)
        raise typer.Exit(2)

    try:
        run_result = run_trunk_check(fix=fix)
    except TrunkCommandError as exc:
        typer.echo(f"error: {exc}", err=True)
        raise typer.Exit(1) from None

    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(run_result.output + (f"\n--- stderr ---\n{run_result.stderr}" if run_result.stderr else ""))
    typer.echo(f"→ wrote full trunk report to {report}")

    if run_result.return_code not in _CLEAN_RUN_RETURN_CODES:
        typer.echo(
            f"error: trunk exited {run_result.return_code} (not a clean 0/1 run); "
            f"report may be partial -- see {report}, skipping all bead changes",
            err=True,
        )
        raise typer.Exit(run_result.return_code or 1)

    findings = parse_findings_by_file(run_result.output)

    if run_result.return_code == 1 and not findings:
        # Exit 1 means trunk itself says there are unresolved issues, so a
        # parser that found none is untrustworthy (format drift, a change to
        # trunk's output shape) rather than a genuinely clean tree -- treat
        # it the same as a non-clean run rather than filing zero beads and
        # potentially pruning every existing one as "resolved".
        typer.echo(
            "error: trunk exited 1 (issues found) but no findings were parsed "
            f"from its output -- see {report}; this usually means trunk's "
            "output format changed. Skipping all bead changes.",
            err=True,
        )
        raise typer.Exit(1)

    try:
        existing_beads = list_existing_beads()

        if not findings:
            typer.echo("✓ no lint issues found")
        else:
            # Only find/create the epic when at least one finding will
            # actually produce a new bead -- a run where every finding
            # matches an already-linked existing bead has nothing to parent,
            # and epic lookup/creation would just be backlog clutter.
            epic_id = None
            if any(finding.path not in existing_beads for finding in findings):
                epic_id = find_or_create_epic(dry_run=dry_run)
            typer.echo(f"→ {len(findings)} file(s) with findings")
            for finding in findings:
                summary = upsert_bead(
                    finding,
                    report_path=report,
                    existing_beads=existing_beads,
                    epic_id=epic_id,
                    dry_run=dry_run,
                )
                typer.echo(f"  {summary}")

        if prune_resolved and re.search(r"(?i)failed to (install|run)|linter .* failed", run_result.stderr + run_result.output):
            typer.echo("warning: trunk reported linter failures; report may be partial, skipping --prune-resolved", err=True)
        elif prune_resolved:
            stale_summaries = close_stale_beads(
                existing_beads,
                current_paths={finding.path for finding in findings},
                dry_run=dry_run,
            )
            if stale_summaries:
                typer.echo(
                    f"→ {len(stale_summaries)} resolved file(s), closing bead(s)",
                )
                for summary in stale_summaries:
                    typer.echo(f"  {summary}")
    except BdCommandError as exc:
        report_bd_failure(exc)
        raise typer.Exit(1) from None
    except BdListParseError as exc:
        typer.echo(f"error: {exc}", err=True)
        raise typer.Exit(1) from None


if __name__ == "__main__":
    app()
