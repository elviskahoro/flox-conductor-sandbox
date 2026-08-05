# Beads + Linear Integration Report

**Date:** 2026-08-05  
**Repository:** `flox-conductor-sandbox`  
**Purpose:** Document whether Beads can act as a pull-only Linear intake for
agent workflows, and capture the setup guidance for applying the integration
in the target repository.

## Executive summary

Beads has a native Linear integration. A custom synchronization service is not
needed. The supported workflow is:

```bash
bd config set linear.team_id "<LINEAR_TEAM_UUID>"
export LINEAR_API_KEY="lin_api_..."
bd linear sync --pull --relations
```

This provides the requested **Linear → Beads** intake model. Pull-only mode
does not push local Beads changes back to Linear. The upstream example also
documents a dry-run mode and a read-only mirror workflow:

- Official workflow: <https://github.com/gastownhall/beads/blob/main/examples/linear-workflow/README.md>
- Beads repository: <https://github.com/gastownhall/beads>

The main implementation risk is not Linear integration; it is Beads database
selection in worktrees. This Conductor workspace resolves Beads to a shared
parent database rather than a workspace-local `.beads` directory. A target
repository must resolve that boundary before configuring Linear, or Linear
issues could be imported into the wrong shared database.

## Findings

### Native integration is present

The installed Beads CLI is:

```text
bd version 1.1.2 (Homebrew)
```

It exposes the native commands:

```text
bd linear pull
bd linear push
bd linear status
bd linear sync
bd linear teams
```

The relevant modes are:

| Command | Behavior | Appropriate for this pilot? |
|---|---|---:|
| `bd linear sync --pull` | Import Linear issues into Beads | Yes |
| `bd linear sync --pull --relations` | Pull issues and dependency relations | Yes |
| `bd linear sync --pull --dry-run` | Preview a pull | Yes |
| `bd linear sync` | Pull, resolve conflicts, then push | No |
| `bd linear sync --push` | Push Beads issues to Linear | No |

The upstream documentation describes pull-only mode as a local Linear mirror.
That matches the desired authority model: Linear is authoritative and Beads
is the agent-facing intake/cache.

### Linear authentication and team access are available

The existing Infisical project contains a secret named `LINEAR_API_KEY`. The
key was used only for a read-only team discovery request and was never printed
or committed.

The key can access these Linear teams:

| Team | Key | UUID |
|---|---|---|
| AI | `AI` | `68392631-5fd7-4d78-9d12-b6b453785cb6` |
| Support | `SUP` | `f0794f8a-8661-4c8c-8025-f3df6cd29407` |
| OSS | `OSS` | `cb9f707c-306f-4999-a3db-bf1ff85e51f0` |
| Design | `DES` | `61bc3489-6f67-4aa6-b068-3e8b89753302` |
| Websites | `WEB` | `302eef18-fc73-4750-b51d-e70afcd2e8a4` |
| Solutions Engineering | `SE` | `5d19065e-250e-4dad-9d3a-a1f011d7df0a` |
| Product | `PRO` | `6b149e2a-1519-4b8d-9377-221c4e85e498` |
| GTM | `GTM` | `0c1edc70-0af0-44ac-a9bc-3dc12eaf2d79` |
| Team | `DLT` | `54db9b91-9d2c-4ca7-8130-b91e2b5ff4c7` |

The proposed pilot team is **AI**.

### Default mappings are sufficient for an initial pilot

The upstream integration supplies defaults for:

- Linear priority `0–4` to Beads priority `4–0/3` semantics.
- Linear state types to Beads `open`, `in_progress`, and `closed`.
- Common labels such as `bug`, `feature`, `epic`, `chore`, and `task`.
- Relations such as `blocks`, `blockedBy`, `duplicate`, and `related`.

Relations are opt-in and should be enabled with `--relations`.

The upstream documentation states that comments, attachments, custom fields,
projects, and cycles are not currently synchronized. Those are expected gaps,
not setup failures.

## Worktree/database hazard

This workspace contains no local `.beads` directory, but Beads reports:

```json
{
  "beads_dir": "/Users/elvis/Documents/ai/.beads",
  "repo_root": "/Users/elvis/Documents/ai",
  "is_redirected": true,
  "dolt_mode": "server",
  "server_port": 54569
}
```

The resolved parent database has this configuration:

```yaml
sync.remote: "elviskahoro/elvis"
issue-prefix: gtm-sdk
```

This is separate from the repository’s documented optional DoltHub workflow,
which targets `elviskahoro/gtm-sdk`. Either way, importing Linear into this
resolved database would mix unrelated sources of truth.

### Required target-repository decision

Before setup in the target repository, verify that `bd context --json` points
to the intended database. Do not proceed solely because a `.beads` directory
appears absent. In worktree environments, Beads can follow redirects or use a
shared parent database.

The target repository should choose one of these explicit designs:

1. **Dedicated local Beads database** — preferred for the Linear intake pilot.
2. **Existing shared Beads database** — only if that database is intentionally
   the Linear-facing source and its existing remote/data ownership is accepted.
3. **Separate planning repository/database** — useful when Linear intake must
   be shared by multiple code repositories.

Do not add Linear configuration to a database that already has an unrelated
DoltHub remote.

## Reference script in this PR

[`scripts/beads-linear-pull.sh`](../scripts/beads-linear-pull.sh) is included as
a reference for the target repository. It demonstrates the intended wrapper
responsibilities:

- Require `INFISICAL_TOKEN` and `INFISICAL_PROJECT_ID`.
- Retrieve `LINEAR_API_KEY` from Infisical without persisting it.
- Configure the AI team UUID.
- Invoke only `bd linear sync --pull --relations`.
- Support `--dry-run`.
- Refuse a detected Beads database with a configured Dolt remote.

It should **not** be copied without retesting database selection in the target
repository. In this workspace, exporting `BEADS_DIR` was not enough to bypass
the existing worktree redirect during `bd init`; the script therefore has not
been treated as a validated local-database bootstrap.

The native Beads commands—not the wrapper—are the integration itself. The
wrapper is only credential and environment glue.

## Recommended setup procedure in the target repository

### 1. Inspect the current Beads resolution

Run from the target repository/worktree:

```bash
bd context --json
bd config list --json
```

Confirm the resolved `beads_dir`, repository identity, backend mode, and any
`sync.remote` value. Stop if it points to a shared or DoltHub database that is
not intended for Linear intake.

### 2. Initialize or select the intended local database

Use the Beads-supported local/stealth workflow appropriate to the target
repository. The resulting database must be isolated from unrelated remotes.
After initialization, rerun:

```bash
bd context --json
```

Record the resulting database location in the target repository’s setup notes.

### 3. Configure Linear without storing the secret

Use the target repository’s secret manager. With Infisical, the pattern is:

```bash
export LINEAR_API_KEY="$(infisical secrets get LINEAR_API_KEY \
  --env=dev --projectId "$INFISICAL_PROJECT_ID" --plain)"
bd config set linear.team_id "68392631-5fd7-4d78-9d12-b6b453785cb6"
bd linear status --json
```

Do not put the API key in `bd config`, a repository settings file, a
Conductor TOML file, or committed shell history.

### 4. Preview and pull

```bash
bd linear sync --pull --relations --dry-run
bd linear sync --pull --relations
```

The commands above are pull-only. Do not use bare `bd linear sync`, because the
bare form is bidirectional and can push local Beads issues to Linear.

### 5. Validate the result

```bash
bd linear status --json
bd ready --json
bd list --json
bd stats
```

Check that imported records have Linear external references and that statuses,
priorities, labels/types, and blocking relations are sensible.

### 6. Repeat safely

Run the same pull again and verify that existing Linear references are updated,
not duplicated. Keep the workflow explicit; do not add it to Conductor setup or
a background scheduler until ownership, rate limits, and failure handling have
been agreed.

## Security and operational notes

- `LINEAR_API_KEY` should be injected into the process environment only.
- Suppress command output that could include secret values in setup logs.
- Never commit `.beads` database files or API credentials.
- Keep pull-only flags explicit in scripts and documentation.
- Treat `bd linear sync --push` and bare `bd linear sync` as privileged actions.
- Start with one Linear team to limit issue volume and mapping surprises.
- Expand to additional teams only after measuring issue volume and validating
  labels/statuses.
- Pulling all historical issues may be large; use `--state open` if the target
  only needs active intake.
- Linear’s API key permissions and team visibility determine what is imported.

## Validation status from this workspace

| Check | Result |
|---|---|
| Native `bd linear` command available | PASS |
| `bd linear status --json` without credentials reports unconfigured state | PASS |
| Infisical contains `LINEAR_API_KEY` | PASS; value not exposed |
| API key can list Linear teams | PASS |
| AI team UUID confirmed | PASS |
| Upstream pull-only workflow verified from official example | PASS |
| Actual Linear issue pull performed | **NOT RUN** |
| Local isolated `.beads` bootstrap validated in this worktree | **BLOCKED by existing Beads redirect** |
| Any Linear write/push performed | NO |

## Conclusion

The Beads + Linear integration is viable and already implemented upstream. The
target repository should use the native pull-only command and keep any custom
script narrowly scoped to secret retrieval and explicit environment setup. The
only unresolved prerequisite is selecting an actually isolated Beads database
in the target repository; that must be solved before importing Linear issues.
