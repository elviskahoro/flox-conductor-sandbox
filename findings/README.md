# Navigating `findings/`

Each `scripts/sandbox-test.sh` run writes one pair of files, named by UTC
timestamp:

- `report-<STAMP>.md` — PASS/FAIL/SKIP summary table plus evidence
  (excerpts are only included for failing/interesting stages; a clean PASS
  just gets a one-line detail). **Read this first.**
- `full-log-<STAMP>.txt` — the complete raw transcript. Only dig in here if
  the report's excerpt isn't enough to understand a result.

See the top-level [README](../README.md) for what the hypotheses (H1-H4)
and stages mean, and how to produce a new run.

## Runs so far, oldest to newest

| Stamp | Environment | Target class? | Headline result |
|---|---|---|---|
| `20260801-021231Z` | Claude Code remote container (Ubuntu 24.04) | No | H1 PASS; H3 FAIL (proxy 403 on GitHub archive fetch — environment-limited, not a flox defect) |
| `20260801-121814Z` | macOS (Darwin, developer machine) | No | H1 PASS; Stage 3a PASS but 3b FAIL (`tar` extraction error, never root-caused) |
| `20260801-123329Z` | Amazon Linux 2023 / Vercel / Conductor cloud | **Yes** | H1 + H3 (all sub-stages) PASS — first clean pass on the real target class |
| `20260801-125246Z` | Same sandbox as above, deliberate re-run with `FLAKE_REPRO=1` | **Yes** | Reproduces the prior run exactly (confirms idempotency) + H2 control PASS |
| `20260801-160419Z` | Fresh Conductor cloud sandbox, never authenticated to FloxHub | **Yes** | H1 + H3 PASS again; **H4 SKIP** — `flox show elvis/conductor-workspace-floxhub-01` fails unauthenticated even though PR #7/#8 confirm it's published for both platforms; `flox search` also can't find it. Leans "auth-gated" but doesn't conclusively rule out "not actually published" |

## Current bottom line (as of the last run above)

- **H1** (prebuilt-catalog manifest activates atomically): PASS on every
  environment tested.
- **H3** (`flox build` repackage shape): PASS on the real target class,
  twice. The two earlier failures are understood/explained, not open
  questions (see table above).
- **H2** (control repro of the original bug): PASS — the target sandbox
  class genuinely has the defect #445 describes, which is what makes the
  H1/H3 passes meaningful evidence rather than "the bug just doesn't exist
  here."
- **H4** (unauthenticated FloxHub fetch): run on a genuinely fresh,
  never-authenticated sandbox (`20260801-160419Z`), and it came back
  **SKIP, not PASS or FAIL** — `flox show
  elvis/conductor-workspace-floxhub-01` fails unauthenticated
  ("no packages matched"), even though the package is confirmed published
  for both `aarch64-darwin` (PR #7) and `x86_64-linux` (see
  [`floxhub-x86_64-linux-publish-20260801.md`](floxhub-x86_64-linux-publish-20260801.md)).
  `flox search` also can't surface it unauthenticated. This rules out
  "package isn't published" as the cause and leans toward "auth-gated,"
  but a SKIP result can't fully confirm that on its own. **Phase D' scope
  is still undecided.** A conclusive answer needs checking the catalog's
  public/private visibility from an already-authenticated context (e.g.
  does an *authenticated* `flox show` on someone else's account see it, or
  is it scoped private to the publishing account?) — not another
  fresh-sandbox run, since every fresh sandbox will hit the same
  `flox show` wall before ever reaching `flox install`.
- Still unexplained: the macOS `tar` extraction failure in the second run —
  worth root-causing if `bd`/`roborev` provisioning needs to work on
  developer Macs, not just cloud sandboxes.

Full narrative synthesis: [PR #3](https://github.com/elviskahoro/flox-conductor-sandbox/pull/3),
and each findings commit's message body (`git log --oneline`, then
`git log -1 <sha>` for the run you care about) — that's where stage-by-stage
analysis lives, not in the generated report files themselves.

## If you're about to add another run

- Read the top-level README's "Running" section first.
- One commit per run; add findings files by explicit name, never `git add -A`.
- Put a stage-by-stage analysis in the commit body (see recent findings
  commits for the expected shape) — don't hand-edit the generated
  `report-*.md`.
- Update the table above with the new run.
- If you run Stage 5 (`FLAKE_REPRO=1`), check for and remove any
  `envs/flake-repro/.flox/env/manifest.lock` it leaves behind — that env is
  deliberately kept lockless (see top-level README).
