# AGENTS.md

Sandbox for provisioning Conductor cloud workspaces and the agent tooling around them (roborev, trunk, RWX, Flox). See [README.md](README.md) for the overview and the skill index; each task has a skill under [`skills/`](skills/). `CLAUDE.md` is a symlink to this file.

## RWX

Agents run CI on [RWX](https://www.rwx.com) before opening a PR. Full detail: [`skills/rwx/SKILL.md`](skills/rwx/SKILL.md).

### Authentication

- Check first: `rwx whoami`. The CLI reads `--access-token`, then `$RWX_ACCESS_TOKEN`, then `~/.config/rwx/accesstoken`. The cloud startup script validates `RWX_ACCESS_TOKEN` and writes that file ([`conductor-startup-script`](skills/conductor-startup-script/SKILL.md)).
- Tokens are scoped to one RWX organization. Injected vars are named `RWX_ACCESS_TOKEN_<OWNER>` / `RWC_ACCESS_TOKEN_<OWNER>`; list names only with `env | grep -E '^RW[XC]_ACCESS_TOKEN_.' | cut -d= -f1`. Export the one matching the repo owner as `RWX_ACCESS_TOKEN` (snippet in the skill). IDs only resolve in the owning org, so switch tokens on not-found/unauthorized.
- Never print, log, or commit a token.

### What you can do

- `rwx run .rwx/<file>.yml --wait --fail-fast`: run CI on the working tree, uncommitted changes included, with no commit or push. `--target <task>` runs one task.
- `rwx results` / `rwx runs list` / `rwx logs`: see what failed and pull the logs. Fix and re-run until green, then open the PR.
- `rwx lint .rwx/<file>.yml`: validate after every edit to `.rwx/*.yml`.
- `rwx sandbox exec -- <cmd>`: persistent cloud sandbox for the inner loop.
- `rwx artifacts download`: fetch outputs, e.g. Dagger results (Dagger can't run in Conductor sandboxes; run it in an RWX task).
- `rwx image build|push`: build container images natively.
- `rwx docs search "<q>"` / `rwx docs pull <path>`: current docs. Use Bash, not WebFetch. Don't write `.rwx` YAML from memory; `rwx docs pull /migrating/rwx-reference` first.
- Migrating GitHub Actions: [`migrate-from-gha`](skills/migrate-from-gha/SKILL.md), then [`review-gha-migration`](skills/review-gha-migration/SKILL.md).
