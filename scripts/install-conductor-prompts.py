#!/usr/bin/env python3
"""Install standardized Conductor prompts into a repository's .conductor settings.

The canonical prompt text lives in prompts/conductor/*.md in this repo
(flox-conductor-sandbox). Conductor only reads custom prompts from a repo's
`.conductor/settings.toml` or `.conductor/settings.local.toml` `[prompts]`
table, and TOML has no include mechanism — so every consuming repo needs the
text copied in. This script is the copier: it reads the .md sources, maps file
names onto Conductor's prompt slots, and writes them into the target settings
file via tomlkit, which preserves comments and unrelated settings verbatim.

Why a script instead of hand-editing the TOML: gtm-sdk hand-embedded its
create_pr prompt in `.conductor/settings.local.toml` and the inline copy
drifted from the .md source — the TOML still instructs `git roborev review`
while gtm-sdk#921 had fixed the .md to call the `roborev` executable directly.
`--check` exists so CI can catch that class of drift; this repo runs it on
itself (self-hosting), and consuming repos can do the same.

Usage (from this repo's root):

    # install into another repo's committed .conductor/settings.toml
    uv run scripts/install-conductor-prompts.py --repo /path/to/target-repo

    # install into that repo's local-only settings.local.toml instead
    uv run scripts/install-conductor-prompts.py --repo /path/to/target-repo --local

    # install into this repo itself (self-hosting; no --repo needed)
    uv run scripts/install-conductor-prompts.py

    # from inside the target repo, without cd-ing here (script path must be
    # absolute: uv run resolves it against cwd, not --project; --no-project
    # --with tomlkit skips the full dependency sync)
    uv run --no-project --with "tomlkit>=0.15.1" \
        /path/to/flox-conductor-sandbox/scripts/install-conductor-prompts.py

    # emit a pasteable [prompts] block (for repos with no committed settings)
    uv run scripts/install-conductor-prompts.py --print

    # verify installed prompts match the .md sources (CI drift guard)
    uv run scripts/install-conductor-prompts.py --check
    uv run scripts/install-conductor-prompts.py --check --repo /path/to/target-repo

    # exercise every installer behavior on a throwaway directory (CI)
    uv run scripts/install-conductor-prompts.py --self-test

Exit status: 0 on success/in-sync, 1 on drift or error.
"""

from __future__ import annotations

import argparse
import contextlib
import io
import sys
import tempfile
import tomllib
from pathlib import Path

import tomlkit

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
DEFAULT_PROMPTS_DIR = REPO_ROOT / "prompts" / "conductor"

SCHEMA_URL = "https://conductor.build/schemas/settings.repo.schema.json"

# The complete [prompts] table from Conductor's settings.repo.schema.json.
# A .md file in prompts/conductor/ must map onto one of these slots; its
# kebab-case stem is converted to the slot's snake_case key.
PROMPT_SLOTS = (
    "general",
    "create_pr",
    "code_review",
    "fix_errors",
    "rename_branch",
    "resolve_merge_conflicts",
)

# Example file names for error messages, so authors see the convention.
_SLOT_EXAMPLES = {
    "general": "general.md",
    "create_pr": "create-pr.md",
    "code_review": "code-review.md",
    "fix_errors": "fix-errors.md",
    "rename_branch": "rename-branch.md",
    "resolve_merge_conflicts": "resolve-merge-conflicts.md",
}

GENERATED_NOTE = (
    "Prompts below are generated from flox-conductor-sandbox "
    "prompts/conductor/*.md by scripts/install-conductor-prompts.py — "
    "edit the .md source and re-run, never this copy."
)


def slot_for_path(path: Path) -> str:
    """Map a prompt file onto a Conductor [prompts] slot, or exit with an error."""
    key = path.stem.replace("-", "_")
    if key not in PROMPT_SLOTS:
        valid = "\n".join(f"  {slot}  ({name})" for slot, name in _SLOT_EXAMPLES.items())
        raise SystemExit(
            f"error: {path.name} does not map to a Conductor prompt slot "
            f"(stem {path.stem!r} -> {key!r}).\n"
            f"Valid slots and their expected file names:\n{valid}"
        )
    return key


def load_prompts(prompts_dir: Path) -> dict[str, str]:
    """Read every .md prompt source, keyed by its Conductor slot.

    Content is normalized to LF line endings with exactly one trailing
    newline so that install and --check agree on a canonical form regardless
    of how the file was saved.
    """
    if not prompts_dir.is_dir():
        raise SystemExit(f"error: prompts directory not found: {prompts_dir}")

    files = sorted(p for p in prompts_dir.glob("*.md") if p.is_file())
    if not files:
        raise SystemExit(f"error: no .md prompt files found in {prompts_dir}")

    prompts: dict[str, str] = {}
    for path in files:
        key = slot_for_path(path)
        text = path.read_text(encoding="utf-8").replace("\r\n", "\n")
        if "'''" in text:
            # The installer embeds content in a TOML literal multiline string
            # ('''), where a ''' sequence would terminate it early.
            raise SystemExit(
                f"error: {path.name} contains ''' , which cannot be embedded "
                "in a TOML literal multiline string"
            )
        prompts[key] = text.rstrip("\n") + "\n"
    return prompts


def multiline_literal_item(key: str, content: str) -> tomlkit.items.Item:
    """Build a tomlkit string item that emits as a '''...''' literal block.

    Parsing a snippet is used deliberately: it guarantees the item re-emits
    byte-for-byte the way it was parsed, instead of relying on how tomlkit's
    string() constructor chooses to represent newlines. TOML trims the first
    newline after the opening ''', so the snippet lays out as
    key = '''<newline>body<newline>''' to yield exactly `content`.
    """
    body = content.rstrip("\n")
    snippet = f"{key} = '''\n{body}\n'''"
    return tomlkit.parse(snippet)[key]


def settings_path(repo: Path, local: bool) -> Path:
    name = "settings.local.toml" if local else "settings.toml"
    return repo / ".conductor" / name


def parse_settings(path: Path) -> tomlkit.TOMLDocument:
    """Parse an existing settings file, or exit with a clear error.

    Both the install and check paths go through here: a settings file
    Conductor cannot parse breaks every workspace in the repo, so never
    act on — or write over — a file that fails to parse.
    """
    try:
        return tomlkit.parse(path.read_text(encoding="utf-8"))
    except tomlkit.exceptions.ParseError as exc:
        raise SystemExit(f"error: {path} is not valid TOML: {exc}") from exc


def load_settings_doc(path: Path) -> tomlkit.TOMLDocument:
    if not path.exists():
        doc = tomlkit.document()
        doc["$schema"] = SCHEMA_URL
        return doc
    return parse_settings(path)


def emit_toml(doc: tomlkit.TOMLDocument, path: Path) -> str:
    """Serialize, then self-validate: the emitted text must parse and every
    value must survive the round trip. A settings file Conductor fails to
    parse would break every workspace in the repo, so never write unverified.
    """
    text = tomlkit.dumps(doc)
    reparsed = tomllib.loads(text)
    for key, value in reparsed.get("prompts", {}).items():
        expected = tomlkit.parse(text)["prompts"][key]
        if value != expected:
            raise SystemExit(f"error: internal round-trip mismatch on prompt {key!r}")
    return text


def table_is_installer_managed(table: object) -> bool:
    """True when the [prompts] table carries this installer's provenance
    marker (the GENERATED_NOTE comment on the table header).

    Only installer-managed tables are mirrored exactly — including removals
    when a source .md is deleted or renamed. A table without the marker is a
    guest: the installer adds/updates its own keys but never removes foreign
    ones, and --check skips the reverse sweep for them.
    """
    comment = getattr(getattr(table, "trivia", None), "comment", "") or ""
    return "install-conductor-prompts.py" in comment


def cmd_install(prompts: dict[str, str], path: Path) -> int:
    doc = load_settings_doc(path)
    fresh = not path.exists()

    if "prompts" not in doc:
        table = tomlkit.table()
        table.comment(GENERATED_NOTE)
        doc["prompts"] = table
    prompts_table = doc["prompts"]

    changed: list[str] = []
    unchanged: list[str] = []
    removed: list[str] = []
    for key, content in prompts.items():
        if key in prompts_table and str(prompts_table[key]) == content:
            unchanged.append(key)
            continue
        prompts_table[key] = multiline_literal_item(key, content)
        changed.append(key)

    # Reverse sweep — installer-managed tables only: a source .md that was
    # deleted or renamed leaves a stale installed key behind, and stale keys
    # are exactly the silent-drift class this tooling exists to catch.
    if table_is_installer_managed(prompts_table):
        for key in [k for k in list(prompts_table.keys()) if k not in prompts]:
            del prompts_table[key]
            removed.append(key)

    if changed or removed:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(emit_toml(doc, path), encoding="utf-8")

    verb = "created" if fresh else "updated"
    if changed or removed:
        details = [f"installed {', '.join(changed)}" if changed else ""]
        if removed:
            details.append(f"removed {', '.join(removed)} (no source .md)")
        print(f"{verb} {path}: " + ", ".join(d for d in details if d))
    else:
        print(f"{path}: already in sync ({', '.join(unchanged)})")
    return 0


def cmd_check(prompts: dict[str, str], path: Path) -> int:
    if not path.exists():
        print(f"drift: {path} does not exist; prompts not installed")
        return 1
    doc = parse_settings(path)
    installed_table = doc.get("prompts", None)
    installed = installed_table if installed_table is not None else {}

    failures: list[str] = []
    for key, content in prompts.items():
        if key not in installed:
            failures.append(f"{key}: not installed in {path}")
        elif str(installed[key]) != content:
            failures.append(f"{key}: installed copy differs from .md source")

    # Reverse sweep — installer-managed tables only: flag keys whose source
    # .md no longer exists (deleted or renamed). Guest tables keep their
    # foreign keys by design, so they are not swept — but a slot-named key
    # with no source .md is still worth surfacing as a note: it may be an
    # installer leftover from a removed source, or an equally legitimate
    # hand-written prompt. Warn, don't fail — a guest table may hold either.
    if installed_table is not None and not table_is_installer_managed(installed_table):
        orphans = sorted(k for k in set(installed) - set(prompts) if k in PROMPT_SLOTS)
        if orphans:
            print(
                f"note: {', '.join(orphans)} in {path} has no source .md — "
                "hand-written prompt, or leftover from a removed source "
                "(guest tables are never auto-removed)"
            )
    if installed_table is not None and table_is_installer_managed(installed_table):
        for key in sorted(set(installed) - set(prompts)):
            failures.append(f"{key}: installed but no source .md (deleted or renamed?)")

    if failures:
        print(f"drift: {len(failures)} prompt(s) out of sync with the .md sources:")
        for failure in failures:
            print(f"  - {failure}")
        print(f"fix: uv run scripts/install-conductor-prompts.py --repo {path.parent.parent}")
        return 1

    print(f"in sync: {len(prompts)} prompt(s) match {path}")
    return 0


def cmd_print(prompts: dict[str, str], path: Path) -> int:
    # `path` is unused here but kept so all subcommands share a signature.
    del path
    # The header comment is the ownership marker: a pasted block is an
    # installer-managed table exactly like an installed one (same detection
    # in table_is_installer_managed), so --check's reverse sweep and the
    # removal path apply to pasted copies too. Without it, a pasted copy has
    # no provenance — exactly how gtm-sdk's hand-maintained copy drifted.
    lines = [f"[prompts] # {GENERATED_NOTE}"]
    for key, content in prompts.items():
        body = content.rstrip("\n")
        lines.append(f"{key} = '''")
        lines.append(body)
        lines.append("'''")
    print("\n".join(lines))
    print(
        f"# Paste the block above into the target repo's "
        f".conductor/settings.toml (or settings.local.toml), and add this "
        f"repo's --check step to that repo's CI so the pasted copy cannot "
        f"drift silently.",
        file=sys.stderr,
    )
    return 0


def _quiet(fn, prompts: dict[str, str], path: Path) -> tuple[int, str]:
    """Run an installer subcommand with its chatter captured; return its
    exit status and captured stdout — keeps the self-test's PASS/FAIL
    lines readable and lets scenarios assert on the reported verb."""
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        return fn(prompts, path), buf.getvalue()


def self_test(prompts_dir: Path) -> int:
    """Exercise every installer behavior on a throwaway directory.

    The CI --check step only covers the happy path (this repo's own in-sync
    state); a regression in idempotency, drift detection, or any error path
    would otherwise go unnoticed while the drift guard silently stops
    guarding. Mirrors the repo's convention of codifying verification into
    CI (validate-pins.sh, the amazonlinux container test).
    """
    failures: list[str] = []

    def check(name: str, ok: bool) -> None:
        print(f"[prompts-self-test] {'PASS' if ok else 'FAIL'}  {name}")
        if not ok:
            failures.append(name)

    prompts = load_prompts(prompts_dir)
    first_key = next(iter(prompts))

    with tempfile.TemporaryDirectory(prefix="conductor-prompts-selftest.") as tmp:
        repo = Path(tmp) / "target"
        settings = repo / ".conductor" / "settings.toml"
        settings.parent.mkdir(parents=True)
        settings.write_text(
            '"$schema" = "https://conductor.build/schemas/settings.repo.schema.json"\n'
            "\n"
            "# precious comment that must survive\n"
            "[scripts]\n"
            'setup = "echo hi"\n',
            encoding="utf-8",
        )

        # 1. Fresh install over existing settings: unrelated content
        #    survives verbatim, values land.
        code, _ = _quiet(cmd_install, prompts, settings)
        check("install exits 0", code == 0)
        after = settings.read_text(encoding="utf-8")
        installed = parse_settings(settings)
        check("comments preserved", "# precious comment that must survive" in after)
        check("schema key preserved", '"$schema"' in after)
        check(
            "unrelated keys preserved",
            installed.get("scripts", {}).get("setup") == "echo hi",
        )
        check("all prompts installed", set(installed.get("prompts", {})) == set(prompts))
        check(
            "installed content matches sources",
            all(str(installed["prompts"][key]) == content for key, content in prompts.items()),
        )

        # 2. Idempotency: re-running is byte-identical.
        snapshot = settings.read_bytes()
        code, _ = _quiet(cmd_install, prompts, settings)
        check("re-install exits 0", code == 0)
        check("re-install is byte-identical", settings.read_bytes() == snapshot)

        # 3. Drift: a mutated copy fails --check, and re-install repairs it.
        marker = f"{first_key} = '''\n"
        settings.write_text(
            settings.read_text(encoding="utf-8").replace(
                marker, marker + "MUTATION MARKER\n", 1
            ),
            encoding="utf-8",
        )
        code, _ = _quiet(cmd_check, prompts, settings)
        check("drift detected (exit 1)", code == 1)
        code, _ = _quiet(cmd_install, prompts, settings)
        check("repair exits 0", code == 0)
        check("repair restores byte-identical copy", settings.read_bytes() == snapshot)
        code, _ = _quiet(cmd_check, prompts, settings)
        check("repaired copy passes check", code == 0)

        # 4. A settings file that was never installed counts as drift.
        absent = repo / ".conductor" / "settings.local.toml"
        code, _ = _quiet(cmd_check, prompts, absent)
        check("missing install reported as drift", code == 1)

        # 5. Invalid TOML is rejected by both paths, with a clear message.
        absent.write_text("BROKEN =\n", encoding="utf-8")
        for label, fn in (("install", cmd_install), ("check", cmd_check)):
            try:
                _quiet(fn, prompts, absent)
                check(f"invalid TOML rejected by {label}", False)
            except SystemExit as exc:
                check(f"invalid TOML rejected by {label}", "not valid TOML" in str(exc))

        # 6. --print output is valid TOML carrying the ownership marker.
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(io.StringIO()):
            cmd_print(prompts, settings)
        printed = buf.getvalue()
        check(
            "print carries ownership marker",
            printed.startswith(f"[prompts] # {GENERATED_NOTE}\n"),
        )
        reparsed = tomllib.loads(printed)
        check(
            "print block parses with matching values",
            {key: str(value) for key, value in reparsed["prompts"].items()} == prompts,
        )

        # 7. Source validation: ''' bodies and unmapped filenames are rejected.
        bad_dir = Path(tmp) / "badsources"
        bad_dir.mkdir()
        (bad_dir / f"{first_key.replace('_', '-')}.md").write_text(
            "contains ''' which cannot be embedded", encoding="utf-8"
        )
        try:
            load_prompts(bad_dir)
            check("''' source rejected", False)
        except SystemExit:
            check("''' source rejected", True)
        (bad_dir / f"{first_key.replace('_', '-')}.md").write_text("fine", encoding="utf-8")
        (bad_dir / "not-a-slot.md").write_text("fine", encoding="utf-8")
        try:
            load_prompts(bad_dir)
            check("unmapped filename rejected", False)
        except SystemExit:
            check("unmapped filename rejected", True)

        # 8. Fresh creation: a repo with no .conductor directory at all.
        fresh_settings = Path(tmp) / "fresh" / ".conductor" / "settings.toml"
        code, out = _quiet(cmd_install, prompts, fresh_settings)
        check("fresh install into bare repo exits 0", code == 0)
        check("fresh settings file created", fresh_settings.exists())
        fresh_doc = parse_settings(fresh_settings)
        check("fresh file carries $schema", "$schema" in fresh_doc)
        check("fresh install reports created", "created" in out)
        code, _ = _quiet(cmd_check, prompts, fresh_settings)
        check("fresh install passes check", code == 0)

        # 9. Ownership: a source .md that disappears is flagged as drift and
        #    removed on re-install — installer-managed tables are mirrored
        #    exactly, never appended to forever.
        two_dir = Path(tmp) / "twosources"
        two_dir.mkdir()
        (two_dir / "create-pr.md").write_text("body one\n", encoding="utf-8")
        (two_dir / "rename-branch.md").write_text("body two\n", encoding="utf-8")
        two = load_prompts(two_dir)
        owned = Path(tmp) / "owned" / ".conductor" / "settings.toml"
        owned.parent.mkdir(parents=True)
        code, _ = _quiet(cmd_install, two, owned)
        check("two-prompt install exits 0", code == 0)
        code, _ = _quiet(cmd_check, prompts, owned)
        check("retired source flagged as drift", code == 1)
        code, out = _quiet(cmd_install, prompts, owned)
        check("retired-key removal exits 0", code == 0)
        check("removal is reported", "removed" in out)
        owned_doc = parse_settings(owned)
        check("retired key removed", "rename_branch" not in owned_doc.get("prompts", {}))
        check(
            "surviving key updated to real source",
            str(owned_doc["prompts"]["create_pr"]) == prompts["create_pr"],
        )
        code, _ = _quiet(cmd_check, prompts, owned)
        check("repaired owned repo passes check", code == 0)

        # 10. Guest tables (no ownership marker) keep their foreign keys:
        #     the installer adds its own but never removes what it didn't
        #     create, and --check skips the reverse sweep for them.
        guest = Path(tmp) / "guest" / ".conductor" / "settings.toml"
        guest.parent.mkdir(parents=True)
        guest.write_text('[prompts]\ngeneral = """custom"""\n', encoding="utf-8")
        code, _ = _quiet(cmd_install, prompts, guest)
        check("guest install exits 0", code == 0)
        guest_doc = parse_settings(guest)
        check("guest table keeps foreign key", guest_doc["prompts"].get("general") == "custom")
        check(
            "guest table gains installer key",
            str(guest_doc["prompts"].get(first_key)) == prompts[first_key],
        )
        code, _ = _quiet(cmd_check, prompts, guest)
        check("guest repo passes check (no reverse sweep)", code == 0)

        # 10b. Guest orphan note: checking with a source set that lacks the
        #      guest's slot-named keys surfaces them as a note (not a
        #      failure) — hand-written or leftover is indistinguishable
        #      from the installer's perspective.
        code, out = _quiet(cmd_check, {"fix_errors": "body\n"}, guest)
        check("guest forward check still fails on missing key", code == 1)
        check(
            "guest orphan keys surface as a note",
            "leftover from a removed source" in out and "create_pr" in out,
        )

    if failures:
        print(f"[prompts-self-test] {len(failures)} failure(s): {', '.join(failures)}")
        return 1
    print("[prompts-self-test] all behaviors verified")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Install standardized Conductor prompts into a repo's .conductor settings."
    )
    parser.add_argument(
        "--repo",
        type=Path,
        default=Path.cwd(),
        help="target repository root (default: current directory)",
    )
    parser.add_argument(
        "--local",
        action="store_true",
        help="target .conductor/settings.local.toml instead of the committed settings.toml",
    )
    parser.add_argument(
        "--prompts-dir",
        type=Path,
        default=DEFAULT_PROMPTS_DIR,
        help=f"directory of .md prompt sources (default: {DEFAULT_PROMPTS_DIR})",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--check",
        action="store_true",
        help="verify installed prompts match the .md sources; exit 1 on drift",
    )
    mode.add_argument(
        "--print",
        action="store_true",
        help="print a pasteable [prompts] TOML block instead of writing a file",
    )
    mode.add_argument(
        "--self-test",
        action="store_true",
        help="exercise every installer behavior on a throwaway directory (CI)",
    )
    args = parser.parse_args()

    if args.self_test:
        return self_test(args.prompts_dir)

    prompts = load_prompts(args.prompts_dir)
    path = settings_path(args.repo.resolve(), args.local)

    if args.check:
        return cmd_check(prompts, path)
    if args.print:
        return cmd_print(prompts, path)
    return cmd_install(prompts, path)


if __name__ == "__main__":
    sys.exit(main())
