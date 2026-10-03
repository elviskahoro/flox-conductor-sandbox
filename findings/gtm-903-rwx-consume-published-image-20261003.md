# gtm-sdk#903 — RWX consume-published-image smoke (2026-10-03)

**Verdict: PASS.** The fix direction gtm-sdk#903's re-evaluation proposed
(consume the GHA-published image instead of running `flox containerize` in
the RWX task container) works end-to-end from inside a real RWX task
container, proven against the real published artifacts.

- Pipeline: `.rwx/gtm-903-consume-published-image.yml` (self-contained —
  see "empty workspace" below)
- Passing run: https://cloud.rwx.com/elviskahoro/runs/c8e7225f761e4aaa83a1d7b57c125650
  (cli-dispatched, 2026-10-03 15:26 UTC)
- gtm-sdk fix branch under test: `agent/integration-consume-published`
  (commit bf5454c9), validated against pinned main f49125cc

## What was validated, mapped to the gtm-sdk fix

| # | Mechanic (as in the gtm-sdk fix) | Result | Evidence (run c8e7225f) |
|---|---|---|---|
| 1 | Deterministic resolution: `git log --first-parent --format=%H -n1 -- <flox-image-publish.yml's exact 8-path set>` | PASS | resolve task: `flox-toolchain:abd17ca5abf1bb15a9390be9ac2fa5cd441d81f2-arm64`, uv pin `0.11.26` read from that commit's `manifest.lock` |
| 2 | Zero flox in the pipeline; image consumed via plain Dagger pull | PASS | consume task pulled the public `flox-toolchain` image with no registry auth, no flox anywhere in the task graph |
| 3 | Bug A A/B: pre-fix awk provenance variant vs fixed cut variant, inside the published image | PASS | `AWK_ABSENT_AS_EXPECTED` + `AWK_VARIANT_FAILS_AS_EXPECTED` (old command fails — live repro of the #516 outage) + `PROVENANCE_SUBSET_OK` (fixed command green; uid 1000, uv 0.11.26, uv/git/gh/time all resolve) |
| 4 | Authenticated Dagger pull of a private GHCR package (`x-access-token` + vault PAT, the pattern the fix needs for private-by-default pytest-deps) | PASS | `PRIVATE_PULL_OK` against private `gtm-sdk/bazel-ci:bcf0a37a…-arm64` using `secrets.GITHUB_TOKEN` from the org-wide default vault |

Scope note: the two writable-path provenance elements (`test -w /opt/venv`,
`test -w /home/runner/.cache/uv`) exist only in the *built* pytest-deps
image; those run in the gtm-sdk publish pipeline itself (whose `uv sync`
build step was already proven on GHA — only the awk check failed there).

## RWX environment discoveries (traps not to re-derive)

1. **Anonymous `git clone` over https from RWX task egress gets a 401**
   (run 5bb6dea6, attempt 1: `fatal: could not read Username for
   'https://github.com'`). gtm-sdk's own pipelines never hit this because
   they clone via the `git/clone` package with the vault token. The smoke
   authenticates a manual clone with `git clone -c http.<url>.extraheader=
   AUTHORIZATION: basic …` — the `-c` *after* the subcommand persists into
   the clone's config, which the partial clone's lazy blob fetches need.
   The token never appears in the echoed command (unexpanded script text)
   or git output.
2. **Cli-dispatched RWX runs start with an EMPTY task workspace**
   (`/var/mint-workspace` literally `total 0`, diag run 647dc3ca). Repo
   content only exists if the pipeline clones it — which is why every
   gtm-sdk pipeline begins with a `code` git/clone task. A pipeline that
   references repo files without cloning first fails with `can't open file`
   (run 5da9148f, attempt 2). The smoke is therefore self-contained: its
   Python is embedded in the yaml and written to TEMP_DIR at run time.
3. **A wrong-but-plausible commit sha is refused loudly**: attempt 1's
   original GTM_SDK_REF had one transposed character; GitHub answers
   `upload-pack: not our ref …` and the partial clone lazy-fetch fails
   (`fatal: bad object`). Extract pinned refs programmatically
   (`git ls-remote | cut -f1`), never hand-copy them.

## Iteration history

| Attempt | Run | Failure | Fix |
|---|---|---|---|
| 1 | 5bb6dea6 | anonymous clone 401 (+ a hand-copied sha typo found locally) | authenticated clone via persisted extraheader; sha extracted programmatically |
| 2 | 5da9148f | smoke script absent — empty task workspace | embed the script in the yaml (self-contained pipeline) |
| 3 | c8e7225f | — | **PASS: ALL CHECKS PASSED** |

## Next (gtm-sdk side, not this repo)

The same mechanics now need to run in the real pipelines: dispatch
`tests-integration.yml` on the fix branch (creates the pytest-deps package
and runs the suite on GHA), dispatch `.rwx/tests-integration.yml` on the
branch (its own `code` git/clone task provides the workspace), then the
daily crons. See the design findings artifact
`design/backlog-202610031512-gtm_sdk_903_integration_cron_findings-findings-01.md`
in the parent repo for the full two-bug diagnosis.
