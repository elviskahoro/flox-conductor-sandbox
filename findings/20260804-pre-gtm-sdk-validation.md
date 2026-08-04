# Pre-`gtm-sdk` validation — 2026-08-04

## Scope

This validation changed only `flox-conductor-sandbox`. No `gtm-sdk` files,
branches, or pull requests were modified.

Final sandbox commits:

- `5974869` — add CI-enforced Infisical/Beads validation;
- `3d43cd0` — repair the stale Dagger installer URL;
- `df175d5` — move Beads read checks into a standalone script;
- `c5cf66b` — handle an empty remote with an ephemeral local fixture.

## Results

| Check | Result | Evidence |
| --- | --- | --- |
| Shell syntax and Python compilation | PASS | `bash -n` on provisioning scripts; `python -m py_compile scripts/dagger_provision_test.py` |
| Local seven-tool Flox provisioning | PASS | Direct-token `scripts/floxhub-provision.sh`; `uv`, `dolt`, `infisical`, `gh`, `git`, `bd`, and `roborev` all resolved from `envs/floxhub-provision/.flox/run` |
| Fresh x86_64 Linux Flox provisioning | PASS | [workflow run 30945235709](https://github.com/elviskahoro/flox-conductor-sandbox/actions/runs/30945235709); `bd 1.1.2`, `roborev 0.63.0`, and the five catalog tools executed |
| `/homeless-shelter` / curl fallback | PASS by existing target-class evidence | Fresh target-class Stage 1–3 evidence remains recorded in `findings/README.md`; the provisioning workflow uses only Flox packages |
| Infisical credentials in Linux container | PASS | Workflow passed masked `INFISICAL_TOKEN` and `INFISICAL_PROJECT_ID` into the disposable container; Beads credential retrieval succeeded |
| Beads/DoltHub bootstrap | PASS | Workflow synced `https://doltremoteapi.dolthub.com/elviskahoro/gtm-sdk` in a fresh container |
| `bd ready`, `bd list`, `bd show` | PASS with empty-remote note | Remote `bd list` was empty; the check created `src-wisp-131` as an ephemeral `--sandbox` fixture and successfully ran `bd show` without pushing it |
| Secret leakage | PASS | Downloaded CI log contains masked names only; no token values were found |
| Unauthenticated H4 preservation | PASS | Default Conductor setup still does not auto-login; the authenticated workflow is manual and disposable |

## Remaining limitation before `gtm-sdk`

The sandbox code now passes explicit Infisical project context to the
FloxHub-token lookup, but the current Infisical project has no
`FLOXHUB_TOKEN` secret. Therefore the *real-value* Infisical-first FloxHub
token fallback was not exercised; the Linux workflow used the configured
repository `FLOXHUB_TOKEN` secret directly. This is an operational secret
configuration gap, not a Linux packaging or Beads/DoltHub failure.

The local Dagger run was not treated as authoritative because this Conductor
worktree caused the local Dagger engine to stall while syncing its source;
the real x86_64 GitHub Actions run completed successfully.

## Gate status

The Linux packaging, seven-tool provisioning, Beads/DoltHub, and secret-safety
gates pass. The pre-`gtm-sdk` gate is **not fully complete** only because the
Infisical project lacks the FloxHub token secret needed to test that fallback
with a real value. No `gtm-sdk` migration should be started until that secret
is intentionally provisioned or explicitly waived.
