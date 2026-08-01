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
| `20260801-141525Z` | Same Amazon Linux 2023 / Vercel / Conductor cloud sandbox | **Yes** | H1 + H3 PASS again; H4 and opt-in H2 skipped |

## Current bottom line (as of the last run above)

- **H1** (prebuilt-catalog manifest activates atomically): PASS on every
  environment tested.
- **H3** (`flox build` repackage shape): PASS on the real target class,
  three times. The two earlier failures are understood/explained, not open
  questions (see table above).
- **H2** (control repro of the original bug): PASS — the target sandbox
  class genuinely has the defect #445 describes (from the prior opt-in run),
  which makes the H1/H3 passes meaningful evidence rather than "the bug just
  doesn't exist here." The latest run left this opt-in stage skipped.
- **H4** (unauthenticated FloxHub fetch): still untested. Blocked on a human
  publishing a throwaway package from an authenticated Mac (`flox publish`,
  #445 Phase A3) — nothing in a cloud sandbox can complete this step. Re-run
  with `FLOXHUB_TEST_PKG=<owner>/<pkg>` once one exists.
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
