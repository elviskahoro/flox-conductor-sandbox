# prompts/

Two kinds of content live here:

- **`conductor/`** — the canonical, cross-repo **Conductor prompts**. These are
  the standardized prompts this repo owns; other repos install them into their
  own `.conductor` settings (see below). Never edit a repo's installed TOML
  copy by hand — edit the `.md` here and re-run the installer.
- **Top-level `*-handoff.md` / `*-research.md` files** — point-in-time session
  artifacts (agent handoffs, decision research) kept for reference. They are
  not installable prompts and follow no schema.

## Why this exists

Conductor reads custom prompts only from a repo's
`.conductor/settings.toml` / `.conductor/settings.local.toml` `[prompts]`
table, and TOML has no include mechanism — so a prompt used in multiple repos
must be copied into each one. gtm-sdk did that by hand (the prompt embedded in
`.conductor/settings.local.toml`) and the copies drifted: the TOML still
instructed `git roborev review --wait` after gtm-sdk#921 had fixed the `.md`
source to call the `roborev` executable directly (git aliases don't exist in
cloud sandboxes).

The convention here fixes both halves:

1. **One canonical source** — `prompts/conductor/<slot>.md`, reviewable and
   diffable like any code.
2. **A mechanical installer** — `scripts/install-conductor-prompts.py` copies
   the `.md` text into a target repo's settings file (comments and unrelated
   settings preserved verbatim, via tomlkit), and `--check` fails CI when an
   installed copy drifts from its source.

## Slot mapping

Conductor's settings schema defines exactly six prompt slots
(`settings.repo.schema.json` → `[prompts]`). A file's kebab-case stem maps to
the slot's snake_case key:

| File in `conductor/`        | Conductor `[prompts]` slot | Purpose                          |
| --------------------------- | -------------------------- | -------------------------------- |
| `create-pr.md`              | `create_pr`                | The "create PR" action           |
| `code-review.md`            | `code_review`              | The code review action           |
| `fix-errors.md`             | `fix_errors`               | The fix-errors action            |
| `rename-branch.md`          | `rename_branch`            | The rename branch action         |
| `resolve-merge-conflicts.md`| `resolve_merge_conflicts`  | The merge-conflict resolution    |
| `general.md`                | `general`                  | Appended to every agent session  |

Only `create-pr.md` exists today (ported from gtm-sdk). Add the others the
same way when needed: drop the `.md` in `conductor/`, run the installer.

## Installing into another repo

From a checkout of this repo:

```bash
# into the target's committed, shared .conductor/settings.toml (recommended)
uv run scripts/install-conductor-prompts.py --repo /path/to/target-repo

# into the target's local-only .conductor/settings.local.toml instead
uv run scripts/install-conductor-prompts.py --repo /path/to/target-repo --local
```

From inside the target repo (the script path must be absolute — `uv run`
resolves it against the current directory, not `--project`; and
`--no-project --with tomlkit` skips the full dependency sync, since
tomlkit is the installer's only third-party import):

```bash
uv run --no-project --with "tomlkit>=0.15.1" \
    /path/to/flox-conductor-sandbox/scripts/install-conductor-prompts.py
```

For a repo with no committed `.conductor` settings, print a pasteable block
and drop it into the settings file by hand:

```bash
uv run scripts/install-conductor-prompts.py --print
```

The printed block carries a generated-copy comment header so a pasted copy
still has provenance — and that repo should add the same `--check` step to
its own CI, since a pasted copy can otherwise drift just as silently as a
hand-edited one.

This repo installs its own prompts into `.conductor/settings.toml`
(self-hosting), and CI (`conductor-startup-script-cloud checks` workflow) runs
`uv run scripts/install-conductor-prompts.py --check` on every push/PR so the
installed copy can never silently drift. Consuming repos can add the same
one-line check.

Constraint: prompt bodies cannot contain `'''` (the installer embeds them in
TOML literal multiline strings). The script rejects such a file loudly.

Ownership: the `[prompts]` table header carries a generated-copy comment.
Tables with that marker are installer-managed — mirrored exactly, so a
source `.md` that is deleted or renamed has its installed key flagged by
`--check` and removed on the next install. A pre-existing `[prompts]` table
*without* the marker is treated as a guest: the installer adds/updates its
own keys but never removes foreign ones, and `--check` skips the removal
sweep for them — though it does print a note for slot-named keys with no
matching source, since those are either hand-written prompts or leftovers
from a removed source.

## Editing a prompt

1. Edit `prompts/conductor/<slot>.md` here — this is the only place to edit.
2. Re-run the installer against this repo (`uv run scripts/install-conductor-prompts.py`)
   and every consuming repo you care about.
3. Commit both together; the `--check` in CI catches anything forgotten.

## What was standardized from gtm-sdk's version

`create-pr.md` is ported from gtm-sdk's `prompts/conductor/create-pr.md`
(including its gtm-sdk#921 fix) with these changes so it works in any repo:

- Roborev is invoked as the plain executable (`roborev review --wait`), not
  the `git roborev` alias — aliases may not exist in cloud sandboxes.
- Relative skill links (`../cli-roborev-guide/SKILL.md`,
  `../trunk-cli-guide/SKILL.md`) became "consult the repo's guide skill if it
  ships one" — the links were dead outside gtm-sdk.
- The "Integration with other skills" table was dropped: every entry linked to
  gtm-sdk-local skills.
- Claims of the form "this repo aliases… / this repo mirrors source layout… /
  this repo lands PRs through the Trunk Merge Queue" became repo-conditional:
  the Trunk merge queue is stated as the ecosystem default with "check the
  repo's agent instructions", and the test-mirroring example is generic.
- `AGENTS.md`/`CLAUDE.md` references became "the repo's agent instructions
  (AGENTS.md/CLAUDE.md)".
- The skill-announcement line ("I'm using the pr-pull-request-creator skill…")
  was dropped — it references gtm-sdk's skill-routing machinery.

Everything else — the why-over-what principle, the squash → roborev →
confirmation → push gate order, the description template, the closing-keyword
grep gate (with the gtm-sdk#609/#628 war story), anti-patterns, examples,
pitfalls — carries over unchanged.
