---
name: conductor-startup-script
description: Use when provisioning a Conductor cloud workspace with scripts/conductor-startup-script-cloud.sh, pasting it into another repo's setup field, setting its env vars (RWX_ACCESS_TOKEN, ROBOREV_AGENT/ROBOREV_MODEL, FIREWORKS_API_KEY, STARTUP_PY_DEV_TOOLS, STARTUP_BEST_EFFORT), bumping a pin, or diagnosing a workspace that came up missing uv/trunk/roborev/rwx/entire/pytest/reflex.
---

# The Conductor startup script

`scripts/conductor-startup-script-cloud.sh` is the single provisioning script for every repo's cloud workspaces. It installs pinned, checksum-verified roborev, trunk, rwx, and entire, plus Python 3.11 on the AL2023 sandbox class (its system python3 is 3.9). It also makes the tools work, not just exist: it validates the rwx token, writes the roborev config, starts the roborev daemon, and smoke-checks the review agent.

For snapshot-build 403s or paste failures, use `conductor-cloud-startup-script-debugging`. To run the container test, use `run-startup-script-tests`.

## Where fixes land: here, never in the consuming repo

- This repo runs the script from its committed `.conductor/settings.toml`.
- Every other repo (gtm-sdk included) gets the script only because an operator pasted it into that repo's Conductor setup field. Conductor has no API for that field, so pasting is the only way in.
- gtm-sdk deliberately has no provisioning of its own (gtm-sdk#944 removed it). Never add a setup script there.
- A workspace that comes up missing tools is always a problem on this side of the paste: the pasted copy is stale, or an env var is unset. Fix it here, then re-paste or set the variable.

Diagnosing a sick pasted workspace:

| Symptom | Cause |
| --- | --- |
| Nothing resolves (`trunk`, `roborev`, …) | The paste is missing or stale. Re-paste the current script. |
| `trunk`/`roborev` resolve but `uv` doesn't | `STARTUP_PY_DEV_TOOLS=1` isn't set in that repo's Conductor env vars. |
| Reviews never run | `FIREWORKS_API_KEY` is missing (the smoke check WARNs). |

Paste-safety: the file must contain no triple double quotes and no backslash line continuations, because Conductor's TOML serialization breaks on them. `scripts/validate-pins.sh` enforces this in CI.

## Environment variables

Set these in the repo's Conductor environment variables, never inline in the script. `.env.cloud` is a template you can fill in and copy over.

- `RWX_ACCESS_TOKEN`: validated before it's written atomically to `~/.config/rwx/accesstoken`, so a bad token never overwrites a good one.
- `ROBOREV_AGENT` (default `pi`) and `ROBOREV_MODEL` (default `fireworks/accounts/fireworks/models/glm-5p3-flash` for pi). The `fireworks/` prefix is required (issue #85). claude-code never logs in from a cloud sandbox, and codex returns 401.
- `FIREWORKS_API_KEY`: Pi + Fireworks can't review without it.
- `STARTUP_PY_DEV_TOOLS=1`: turns on uv, pytest, and Reflex (see below). Each consuming repo must set it itself; pasting the script alone never enables it.
- `STARTUP_BEST_EFFORT=1`: a failed tool stage is recorded but doesn't fail setup. A Python 3.11 failure or a requested pytools failure still exits non-zero.

## Reviews are on demand, never a background hook

The review gate is `roborev review --wait`. The script never installs a post-commit auto-review hook, because roborev's hook can only enqueue a background job, and findings that surface after the fact get lost. Concretely:

- It never runs `roborev init` (that installs hooks, and there's no flag to suppress them). It writes `.roborev.toml` directly instead.
- It removes leftover roborev hooks.
- It never writes into a machine-global `core.hooksPath`. It WARNs instead.

A committed `.roborev.toml` is treated as the repo's own and never overwritten. In this repo, set `agent`/`model` there, not via `ROBOREV_AGENT`.

## Entire

`entire` and `git-remote-entire` land on PATH, and that's all. The script never runs `entire enable`, because that writes `.entire/settings.json` plus agent hook files, and committing those is a per-repo decision. To enable a repo, run `entire enable --agent <agent>` once and commit `.entire/settings.json` and `.entire/.gitignore`. For headless login, see `entire-device-login`.

Useful read-only queries: `entire status`, `entire checkpoint list`, `entire trail list --project gh/<owner>/<repo>`, `entire trail show <trail>`, `entire review --list`.

## Python dev tools (`STARTUP_PY_DEV_TOOLS=1`, issue #44)

- `uv` is the pinned release binary, installed in `/usr/local/bin`, with a `~/.local/bin` fallback when sudo isn't available. The Flox manifests' uv only exists inside an activation, so it doesn't count.
- `pytest` and `reflex` are installed into a uv-managed venv at `~/.conductor-pytools`, with their commands symlinked onto PATH.
- Supported invocations: `pytest`, `reflex`, `~/.conductor-pytools/bin/python -m pytest`. A bare `python3 -m pytest` is not supported, because system site-packages are left clean.
- Only the Reflex package is installed. Its frontend toolchain (bun/node, needed for `reflex init` and `reflex run`) is out of scope.
- A failure here is always fatal, because a requested tool must never be missing from a workspace that looks ready.

## Pins

Pins live in the script's pins block. Always read the current values there, never from docs.

- A uv bump must change three things together: the startup script, `envs/prebuilt`, and `envs/floxhub-provision` (and their locks). `scripts/validate-pins.sh` cross-checks them.
- pytest and Reflex are pinned only in the startup script.
- On re-runs, a working uv is reused as-is, so a `UV_PIN` bump only applies to fresh installs. pytest and Reflex are upgraded in place.
- Entire: `ENTIRE_PIN` plus a per-platform `ENTIRE_SHA256_*` constant for each platform. The re-pin runbook is in the pins block.

## Deferred stages (issue #40): proven, not wired in yet

| Stage | Executable reference |
| --- | --- |
| Flox bootstrap on Linux (dnf rpm, `/dev/fd`, hand-started `nix-daemon`, `~/.bashrc` self-heal) | `scripts/sandbox-test.sh` Stage 1; `FLOX_BOOTSTRAP_CMD` in `scripts/dagger_provision_test.py` |
| FloxHub token → `FLOX_FLOXHUB_TOKEN` | `scripts/floxhub-provision.sh` (see `floxhub-auth`) |
| Activate the host repo's committed Flox env | `FLOXHUB_ACTIVATE_DIR=<repo> bash scripts/floxhub-provision.sh` |

Until these are wired in, run the helpers by hand after the startup script.
