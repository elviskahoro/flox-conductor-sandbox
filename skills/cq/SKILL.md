---
name: cq
description: Use the `cq` CLI (mozilla-ai/cq), a shared knowledge store for coding agents. Use when installing cq, querying/proposing/confirming/flagging knowledge units (KUs), configuring local vs remote stores (CQ_ADDR, CQ_API_KEY, CQ_LOCAL_DB_PATH), installing cq into agent hosts, running the cq MCP server, or debugging cq errors.
---

# cq CLI

`cq` stores short "knowledge units" (KUs): insights about pitfalls, stale versions, and quirks that agents hit. Agents query before acting and propose after discovering something non-obvious. It works fully offline against a local SQLite DB; a remote store is optional. Verified against cq v0.18.0 (Linux x86_64).

## Install

- Go: `go install github.com/mozilla-ai/cq/cli@latest`
- Release binary (no Go needed): releases tagged `cli/vX.Y.Z` at github.com/mozilla-ai/cq. Assets: `cq_{Linux,Darwin,Windows}_{x86_64,arm64}`, plus `checksums.txt`.
  ```bash
  gh release download cli/v0.18.0 -R mozilla-ai/cq -p cq_Linux_x86_64.tar.gz -p checksums.txt
  sha256sum -c checksums.txt --ignore-missing
  tar -xzf cq_Linux_x86_64.tar.gz && cp cq ~/.local/bin/
  ```
- Not the PyPI/npm package named `cq`; those are unrelated projects.
- Check: `cq --version` -> `cq v0.18.0 (<sha>), built <date>`.

## Global flags / env (every command)

| Flag | Env | Meaning |
|---|---|---|
| `--db-path` | `CQ_LOCAL_DB_PATH` | Local SQLite path. Default `~/.local/share/cq/local.db` |
| `--addr` | `CQ_ADDR` | Remote API address (unset = local-only) |
| `--api-key` | `CQ_API_KEY` | Remote data-plane key (never stored by `cq auth`) |
| `--timeout` | `CQ_TIMEOUT` (seconds) | Operation timeout, default 30s |

For experiments, point `CQ_LOCAL_DB_PATH` at a temp file so you don't pollute the real store.

## Commands

### query: search before acting
`cq query --domain <tag>... [--language L] [--framework F] [--pattern P] [--limit 5] [--format text|json]`
- `--domain` required, repeatable. Language/framework filters repeatable.
- No match prints `No matching knowledge units found.` and exits 0.

### propose: add a KU
`cq propose --summary S --detail D --action A --domain tag... [--language L] [--framework F] [--pattern P] [--format json]`
- Required: `--summary`, `--detail`, `--action`, `--domain`. Missing -> `Error: required flag(s) ... not set`, exit 1.
- Returns an id like `ku_<32hex>`, starting confidence 0.5, tier `local`.
- Strip project-specific details and secrets first; proposals may be shared.

### confirm / flag: feedback on a KU
- `cq confirm <unit_id>`: +confidence (0.5 -> 60% observed).
- `cq flag <unit_id> --reason duplicate|incorrect|stale [--detail text] [--duplicate-of <id>]`: lowers confidence (60% -> 45% observed). `--reason` required.
- Units whose tier is `private`/remote need a configured remote, otherwise: `knowledge unit X has tier private but no remote API is configured` (exit 1).

### status
`cq status [--format json]`: total count, per-domain counts, recent units, confidence histogram (buckets 0.0-0.3, 0.3-0.5, 0.5-0.7, 0.7-1.0), tier counts.

### drain
`cq drain [--dry-run] [--format json]`: push local KUs to the remote and delete the pushed ones locally. Requires `CQ_ADDR`, else `no remote API configured` (exit 1). Use `--dry-run` first.

### auth
`cq auth login <provider> | logout | status | providers | key`: interactive OIDC sign-in to the cq platform (control plane). All need `CQ_ADDR` (`providers` errors `no platform address configured` without it). `status` when signed out exits 1 with `credstore: no credentials stored`. Not exercised beyond that (needs a platform).

### install: wire cq into an agent host
`cq install --target <host>... [--dry-run] [--project DIR] [--uninstall]`
- Hosts: claude, codex, copilot, cursor, devin-desktop, opencode, pi. Idempotent.
- Always `--dry-run` first. Observed plans: `claude` -> adds the claude marketplace/plugin; `codex` -> `~/.agents/skills`, `~/.codex/config.toml`, `~/.codex/AGENTS.md`; `pi` -> `~/.agents/skills`, `~/.pi/agent/prompts`, `~/.pi/agent/AGENTS.md`.
- `--project` is not supported by every host (`host claude does not support project installs`).
- Claude Code alternative: `claude plugin marketplace add mozilla-ai/cq && claude plugin install cq`.

### mcp
`cq mcp`: MCP server on stdio. Verified tools: `query`, `propose`, `confirm`, `flag`, `status` (server name `cq`).

### prompt
`cq prompt skill|reflect|status`: print the canonical agent skill / `/cq:reflect` / `/cq:status` prompts for hosts without the plugin. `cq prompt skill` is the authoritative agent-behavior spec (query-first loop, VIBE√ safety check before propose, confirm/flag etiquette).

### completion / help
`cq completion <shell>`, `cq help <cmd>`.

## Agent workflow (from `cq prompt skill`)
1. Before non-trivial work (external APIs, new libs, CI/infra, errors): `query` with domain tags.
2. If guidance helps, `confirm` it right away; if wrong/stale, `flag` with reason.
3. When you learn something non-obvious, draft a KU, show the user, and `propose` only after approval (unattended runs follow the headless rules in the prompt).
4. Before finishing: confirm used KUs, flag bad ones.

## Gotchas
- Exit codes: 0 success (including empty query), 1 for any error (missing flags, no remote, not signed in).
- `--format json` on query/propose/status/drain gives machine-readable output; confirm/flag print text only.
- Error output goes with `Error:` prefix; `auth status` prints a hint and an error line.
- Local-only mode needs no config; remote features (drain, private-tier confirm/flag, auth) all require `CQ_ADDR`.
- Not verified: real remote server, `auth login`, `auth key`, `drain` without `--dry-run`, actually running `install` (only dry-run).
