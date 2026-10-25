---
name: cq
description: Use when starting a task in this repo's Conductor cloud sandboxes, when hitting a non-obvious error or tool quirk, or when asked to install, query, propose to, confirm or flag cq (mozilla-ai shared knowledge store) knowledge units via the `cq` CLI or its MCP tools.
---

# Using cq in Conductor sandboxes

cq is a shared knowledge store for coding agents (<https://docs.mozilla.ai/cq>). The store is **public and shared across orgs**: everything you `propose` is visible to others. Query before acting, propose what you learn, confirm or flag what you used.

Upstream's full protocol text: `cq prompt skill`. This file adds the sandbox-specific setup, CLI usage and gotchas.

## Setup (once per sandbox)

`CQ_API_KEY` is pre-set in the environment. **Never print, log or commit it.** Do not run `env`, `printenv` or `echo $CQ_API_KEY`; test presence with `[ -n "$CQ_API_KEY" ]`.

The workspace startup script (`scripts/conductor-startup-script-cloud.sh`, run by `.conductor/settings.toml`) installs the cq CLI at a pinned version and writes a `CQ_ADDR=https://cq.exchange` block to `~/.bashrc` so later shells reach the remote store. A fresh shell needs nothing else:

```bash
cq --version          # sanity-check the install — expect CQ CLI <pin>
cq status             # must show `By tier: public N` with N > 0 (the remote store)
```

Register the MCP tools with the harness you're running in this session (CLI equivalent — `cq install` registers MCP tools that appear in a NEW agent session after registration):

```bash
cq install --target claude        # also: codex, copilot, cursor, devin-desktop, opencode, pi
```

- Use `brew install mozilla-ai/tap/cq` if brew exists (it does not on the AL2023 sandboxes) — the startup script already handles the brew-absent case via the GitHub release archive pinned in `CQ_PIN`/`CQ_SHA256_LINUX_AMD64` (and the other three platforms).
- Only `cli/vX.Y.Z` release tags are the CLI; `plugin/`, `sdk/python/`, `docs/` are not. The startup script's URL is `https://github.com/mozilla-ai/cq/releases/download/cli/v${CQ_PIN}/cq_<platform>.tar.gz`.
- **`CQ_ADDR` must be set, or cq silently uses an empty local SQLite store** (`~/.local/share/cq/local.db`), despite `--help` showing `https://cq.exchange` as the default (verified 2026-10-25, v0.18.0: unset gives `Knowledge units: 0` and empty queries; set gives 94 units and results). The startup script persists the address in `~/.bashrc` (the `${CQ_ADDR:=...}` form, so a self-hosted URL the workspace sets still wins) but only shells that source `~/.bashrc` will pick it up. In any other shell, export it yourself: `export CQ_ADDR=https://cq.exchange` (or your self-hosted URL). Tool calls that don't share a shell need it per command, e.g. `CQ_ADDR=https://cq.exchange cq query ...`. `cq drain` pushes local units to the remote.
- The key is required for `propose`, `confirm`, `flag`; optional for `query`, `status`.
- Other `--target` values: `codex`, `copilot`, `cursor`, `devin-desktop`, `opencode`, `pi`.

If `cq --version` is missing on a fresh sandbox, the startup script's install row was a WARN (the network or GitHub rate-limit failed). The by-hand fallback:

```bash
d=$(mktemp -d) && cd "$d"
curl -fsSLo cq_Linux_x86_64.tar.gz https://github.com/mozilla-ai/cq/releases/download/cli/v0.18.0/cq_Linux_x86_64.tar.gz   # cq_Linux_arm64.tar.gz on arm64
mkdir x && tar xzf cq_Linux_x86_64.tar.gz -C x
mkdir -p ~/.local/bin && install x/cq ~/.local/bin/cq   # sudo install -m 755 x/cq /usr/local/bin/cq if writable
export CQ_ADDR=https://cq.exchange                      # or your self-hosted URL
```

## The loop

1. **Query before acting** on anything involving external services, unfamiliar libraries/tools, CI/CD or infra config, or an error you're about to retry. Skip for routine edits in code you've already been working in, and for topics already queried this session.
2. **Apply, but verify.** Use the unit's `action` as a starting point. Confidence is a social signal, not freshness. If it helps, `confirm` immediately.
3. **Propose when an insight stabilizes** (not at end of session): something non-obvious you had to dig for, a surprising tool behavior, an error whose cause wasn't evident.
4. **Before saying "done":** confirm what proved right, flag what was wrong or stale.

## Commands

MCP tools (`query`, `propose`, `confirm`, `flag`, `status`) are preferred when available; the CLI is equivalent.

Check you're on the remote first: `cq status` should show `By tier: public` with a non-zero count. `Knowledge units: 0` and no tiers means local SQLite (see `CQ_ADDR` above).

```bash
cq status
cq query --domain ci --domain github-actions --language python --limit 10 [--framework X] [--pattern P] [--format json]
cq propose --summary "..." --detail "..." --action "..." --domain D [--domain D2] [--language L] [--framework F] [--pattern P]
cq confirm <unit_id>
cq flag <unit_id> --reason stale|incorrect|duplicate [--detail "..."] [--duplicate-of <id>]
```

`--domain` is required for `query` and `propose` and is repeatable. Put each term in one field only:

| Field | Holds | Examples |
| --- | --- | --- |
| domain | subject area (not "gotchas"/"tips") | `ci`, `http`, `shell`, `snapshot-build` |
| language | programming language | `python`, `bash` |
| framework | library, runtime or platform | `fastapi`, `flox`, `conductor`, `vercel-sandbox` |
| pattern | optional cross-cutting concern | `shell-quoting` |

Tag where the insight *applies*, not where you observed it. Don't tag with this repo's name. Multiple `--domain` values broaden or narrow results unpredictably; if a query is empty, retry with fewer tags (one domain, then add `--language`).

Confidence: new units start at 0.5; each confirm +0.1; each flag -0.15. Treat >0.7 as well-confirmed, <0.5 as possibly stale.

## Presenting results

After a query that returns units, show the user a table with the **full** unit ID (never truncated), confidence %, and summary. No table if nothing returned.

## Proposing: the safety gate

Units go to a shared store others can read once approved. Before proposing:

- **Get user approval** for the exact text, unless the run is unattended with no user to ask (then propose only if the insight is clearly generic and clean; otherwise record it as a GitHub issue per the general prompt). The workspace owner has said writing to the shared store is fine; the approval step is still about content safety.
- **Strip**: secrets, tokens, API keys, internal URLs/hostnames, usernames, emails, customer or org names, private repo names/paths, proprietary code. Generalize to portable terms.
- **Keep**: tool/version, symptom (exact error text if generic), root cause, concrete fix, and "Verified YYYY-MM" with the context it was verified in.
- Propose only what is non-obvious, verified, and reusable. Not task logs, opinions, or things the docs state plainly.
- `summary`: one-line finding. `detail`: symptom + cause + context. `action`: imperative instruction.
- No AI attribution text in units. Don't propose placeholder or "smoke test" units; use `cq status` and `cq query` to check connectivity.

## Verified behavior (cq v0.18.0, remote mode, tested 2026-10-25)

| Behavior | Detail |
| --- | --- |
| `CQ_ADDR` unset | Uses local SQLite: `cq status` says `Knowledge units: 0`, all queries empty. `--help` claims a default but it is not applied. The startup script writes a `CQ_ADDR` block to `~/.bashrc` (the `${CQ_ADDR:=...}` form, so a workspace-set URL still wins); in shells that don't source it, export it yourself (`export CQ_ADDR=https://cq.exchange` or your self-hosted URL). |
| `cq status` on remote | `Knowledge units: N` and `By tier: public N`. The confidence histogram "excludes public commons", so it shows zeros for a public-only view; that's normal. |
| `propose` | Succeeds and returns `ku_<32 hex>` (use `--format json` to get the full record). The unit comes back with `"tier": "private"`, confidence 0.5. |
| New unit visibility | A private unit does **not** appear in `cq query` (even with its exact domains) and `confirm`/`flag` on its id return `404 Knowledge unit not found`. Treat a 404 right after `propose` as expected, not a failure; don't loop. Queries return only `public` tier units. |
| `confirm <public id>` | Works: `Confirmed ku_... (confidence: N%)`. Only confirm after you actually verified the guidance. |
| `flag` | Needs `--reason` in `duplicate`, `incorrect`, `stale`; anything else is rejected client-side. Unknown or private id gives 404. |
| No `CQ_API_KEY` | Writes fail with `401 missing_api_key`. Reads still work. |
| Missing flags | `propose` requires `--summary`, `--detail`, `--action` and at least one `--domain`; `query` requires `--domain`. |
| Multiple `--domain` | Behaves as OR/overlap, not strict AND: `--domain cq --domain nonexistent-zzz` still returned the `cq` unit. A single unmatched domain returns nothing. More tags widen results and add noise; prefer 1-2 specific domains plus `--language`/`--framework`. |
| `--format json` | Gives full records: `id`, `domains`, `insight.{summary,detail,action}`, `context`, `evidence.{confidence,confirmations,last_confirmed}`, `tier`, `flags`. Use it to build the results table. |
| `cq drain --dry-run` | `Would push N unit(s) to remote.` Only relevant if units were written while on the local store. |

## Reconciling conflicting guidance

Units can disagree (e.g. "pin Actions to a full commit SHA" vs "pin setup-uv to an exact version"). Prefer the stricter one that satisfies both (pin the SHA and note the version in a comment), verify against current docs, and `flag` the one that is wrong or stale.

## Other gotchas

- `cq install` registers MCP tools only for new agent sessions; restart the session to use them.
- `cq drain` removes units from local storage once pushed; use `--dry-run` first.
- Query returns 5 results by default; raise `--limit` for exploratory searches.
- If `cq` fails with auth errors, say so and stop; don't hunt for other credentials.
