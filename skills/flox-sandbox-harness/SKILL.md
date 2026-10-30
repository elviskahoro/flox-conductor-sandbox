---
name: flox-sandbox-harness
description: Use when running or interpreting scripts/sandbox-test.sh (the gtm-sdk#445 Flox hypothesis harness), reading findings/report-*.md, deciding what a Stage 1–7 PASS/FAIL/SKIP means, or touching envs/prebuilt, envs/repackage, envs/flake-repro, envs/floxhub-consume, or envs/floxhub-provision.
---

# Flox sandbox harness

`scripts/sandbox-test.sh` answers one question on a fresh Conductor cloud sandbox: do prebuilt Flox packages fix the flake source builds that break there (gtm-sdk#445)? It never hard-fails. Each run writes `findings/report-<UTC>.md` (the summary, so read it first) and `findings/full-log-<UTC>.txt`.

**Read [issue #16](https://github.com/elviskahoro/flox-conductor-sandbox/issues/16) before drawing conclusions.** It holds the verdict, the evidence index (including which runs are contaminated), and the known traps. It supersedes #4, #5, and #11.

## Running

`.conductor/settings.toml` runs it during setup (`CONDUCTOR_STARTUP_MODE=1`) and logs to `~/.conductor-setup.log`. To run it by hand:

```bash
bash scripts/sandbox-test.sh                       # default stages
FLAKE_REPRO=1 bash scripts/sandbox-test.sh         # + Stage 5 (slow: real Go build attempt)
FLOXHUB_TEST_PKG=<owner>/<pkg> bash scripts/sandbox-test.sh   # Stage 4 target (default elvis/conductor-workspace-floxhub-01)
TEST_AUTH_PLUMBING=1 FLOXHUB_TOKEN=<t> bash scripts/sandbox-test.sh      # + Stage 6, authenticates this sandbox for good
TEST_FLOXHUB_PROVISION=1 FLOXHUB_TOKEN=<t> bash scripts/sandbox-test.sh  # + Stage 7, authenticates this sandbox for good
```

## Stages and what a result means

| Stage | Tests | Result so far |
| --- | --- | --- |
| 1 | Flox bootstraps (rpm/deb, `/dev/fd` shim, hand-started `nix-daemon`) | PASS on target class |
| 2 (H1) | gtm-sdk's five catalog-only packages (`uv`, `dolt`, `infisical`, `gh`, `git`) materialize in one `flox activate`, all under `.flox/run/.../bin` | PASS in every environment. Removing the flake pins fixes provisioning. |
| 3 (H3) | `flox build` works, including repackaging pinned, checksum-verified upstream `bd`/Hookdeck binaries into `$out/bin` | PASS on target class. Repackaging is a viable publish source. |
| 4 (H4) | An unauthenticated sandbox can `flox install` from a project FloxHub catalog | SKIP, which is expected (see traps) |
| 5 (H2, opt-in) | The `bd` flake pin reproduces the `/homeless-shelter` failure | PASS: this sandbox really has the defect, which is what makes Stage 2's PASS meaningful. If it *succeeds*, Stage 2 is weaker evidence. |
| 6 (opt-in) | After `floxhub-login.sh`, `flox activate` resolves a FloxHub `pkg-path` (`envs/floxhub-consume`) | A FAIL means the auth recipe itself needs rework |
| 7 (opt-in) | `scripts/floxhub-provision.sh` activates `envs/floxhub-provision` (the five tools plus `elvis/bd`, `elvis/roborev`) | PASS on `aarch64-darwin` and `x86_64-linux`. `aarch64-linux` is out of scope. |

## Traps

- **Stage 4 only means something on a never-authenticated sandbox.** Running Stage 6 or 7, `floxhub-login.sh`, or setup with `FLOXHUB_AUTOLOGIN=1` disqualifies that sandbox forever. Run `20260801-201328Z` reported PASS on an authenticated machine, so ignore that conclusion.
- **Stage 4 SKIP is the correct answer.** A bare `flox publish` always lands in the publisher's private catalog, and there's no flag to make a package public (`--org` shares with a paid org, never the public). Unauthenticated consumption needs token plumbing (see `floxhub-auth`).
- Each `envs/*` directory is its own Flox environment, so one failing stage can't poison the others.
- `envs/prebuilt` and `envs/repackage` commit their `manifest.lock` (matching gtm-sdk), so Stage 2 materializes from a lock, like a fresh gtm-sdk sandbox does. `envs/flake-repro` stays lockless, because locking a flake pin means evaluating the flake, which is exactly what's under test.
- `envs/repackage` carries `curl`/`gnutar`/`gzip`/`coreutils`/`cacert` as build deps, because `sandbox = "off"` builds run inside the activated env. A repo that adopts this shape inherits those deps, or should move the builds to a dedicated publish env.
- Out of scope: the beads DB bootstrap and `uv sync`. Tool provisioning is the thing under test.

Commit new findings back, and add the run to the index in `findings/README.md`.
