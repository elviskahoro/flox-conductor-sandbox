---
name: rwx
description: Use when working with RWX: creating or modifying a `.rwx/` run definition, validating a change against remote CI with the RWX CLI (rwx run --wait, rwx results, rwx logs, rwx artifacts) so a pull request has a passing build before review, checking why CI is red or what is failing on a branch, or running tests in an RWX sandbox.
---

# RWX: pull requests from agents with passing builds

Sources: the [rwx-cloud/skills](https://github.com/rwx-cloud/skills) `rwx` skill (MIT, v0.2.0), [Truly continuous integration](https://www.rwx.com/blog/ensuring-pull-requests-from-agents-have-passing-builds) (Jordan Sanders, 2026-01-21). Requires RWX CLI 3.0.0 or newer. See also [RWX logs](https://www.rwx.com/blog/rwx-logs) (Jason Robinaugh, 2026-01-07) and [Build container images](https://www.rwx.com/docs/guides/build-container-images), [RWX Sandboxes](https://www.rwx.com/blog/rwx-sandboxes), and the [calculator-demo `claude.yml`](https://github.com/rwx-cloud/calculator-demo/blob/main/.rwx/claude.yml).

Reviewers don't want agent PRs without a green build, and agents often can't run the full suite locally. RWX lets the agent iterate against remote, parallelized CI until it passes, with no commit or push per attempt.

## Before you start

Run `rwx whoami` to confirm the CLI is signed in, and update the CLI if it is out of date.

## Writing and validating run definitions

Don't write `.rwx/*.yml` from memory. Pull the reference and read all of it without truncating:

```bash
rwx docs pull /migrating/rwx-reference
rwx docs search "<query>"          # for anything the reference doesn't cover, then rwx docs pull the hit
rwx lint .rwx/<name>.yml           # validate before running
```

`rwx run` doesn't need a commit or push, even when the definition references a commit SHA: RWX patches the git clone with your local contents.

## Checking CI status

To see what is failing on the current or a given branch, start with `rwx results -h`, then `rwx logs` for the failing task.

## Migrating from GitHub Actions

Use the [`migrate-from-gha`](../migrate-from-gha/SKILL.md) skill, then [`review-gha-migration`](../review-gha-migration/SKILL.md).

## Commands

- `rwx run --wait` starts a run and blocks until it finishes. Use it as the agent's validation step.
- `rwx results` shows what happened in a run (which tasks passed or failed).
- `rwx logs` gives task logs for troubleshooting a failure.
- `rwx artifacts` fetches artifacts a run produced.
- Every command accepts `--output json`. Use it when parsing results programmatically.

## Loop

1. Make a change.
2. `rwx run --wait` (add `--output json` if parsing).
3. On failure, use `rwx results`, then `rwx logs` / `rwx artifacts` for the failing task, fix, and go to 2.
4. Open the PR only once the run is green.

## Sandboxes (inner loop)

RWX sandboxes are persistent cloud environments built from the same run definitions as CI. The agent stays local (your config, tools, oversight) while execution is offloaded. Local changes sync up before each command and back down after. Content-based caching snapshots automatically, so there are no Docker/OCI images to maintain. Each agent gets its own sandbox, so parallel agents and git worktrees don't need per-worktree local setup. They also work when the agent runs somewhere without a dev environment (e.g. Claude Code on the web).

```bash
rwx sandbox init                  # creates .rwx/sandbox.yml from a starter template
rwx sandbox exec -- npm test      # run a command; the sandbox persists between calls
rwx run .rwx/ci.yml --wait        # outer loop: full CI
```

`.rwx/sandbox.yml` in the article's example (`rwx-cloud/sandbox-example`): `on.cli.init.commit-sha` set from `${{ event.git.sha }}`; base `ubuntu:24.04` with `rwx/base` 1.0.3; a `code` task calling `git/clone` (`preserve-git-dir: true`, `repository`, `ref: ${{ init.commit-sha }}`, `github-token: ${{ github.token }}`); and a `sandbox` task that uses `code` and runs `rwx-sandbox`. Customize it for your project, and make sure repo access is configured.

Agent workflow: iterate with `rwx sandbox exec -- <targeted tests>`, then confirm with `rwx run .rwx/ci.yml --wait` before pushing or opening a PR. Installing the [RWX skill](https://www.rwx.com/docs/ai) teaches agents to do this, or instruct it explicitly. The "seconds to start" claim is the vendor's own, and sync timing is worth testing in your workflow.

## Pulling full logs

Test results are semantic output in the RWX UI, and the RWX MCP server surfaces failed tests to agents. Use full logs when you need stack traces or print/trace output.

- `rwx logs <taskId>` downloads a task's logs (CLI 2.3.0+). Take the task ID from the RWX UI URL.
- Choose a download location the agent can read. Check the CLI reference for the flags; the article names only `--json` and `--auto-extract`.
- Example, listing downloaded log files that contain `ERROR`:

```bash
rwx logs <taskId> --auto-extract --json | jq -r '.outputFiles[]' | xargs grep -l "ERROR"
```

- Don't paste whole logs into the prompt. Thousands of lines bloat context, so grep or filter the files instead.
- The MCP server's failed-task output tells agents how to download logs via the CLI. Treat the CLI as a complement to MCP, not a replacement.

## Building container images

RWX builds OCI images natively (`docker build` also works on RWX). Full YAML lives in the `rwx-cloud/rwx-image-example` repo; this is the shape.

- An `image` task configures the image by writing to `$RWX_IMAGE/`: `command`, `user`, and so on.
  ```bash
  echo "$PWD/script.sh" | tee $RWX_IMAGE/command
  ```
- Push with `rwx image push <task-id> --to <remote-tag>`, where the task ID is the `image` task's. Other commands: `rwx image build` (build and pull locally), `rwx image pull`.
- Node.js example: a base like `node:24.11.0-trixie-slim` with `config: none`, then tasks `system` (apt packages, including `curl` and `jq` for `git/clone`), `code` (`git/clone` at the commit SHA), `npm-install` (`npm ci --omit=dev`), and `image`.
  - No `COPY` step. Start with all files and filter per command: `npm-install` filters on `package.json` and `package-lock.json`, so it stays cached until they change.
  - In `image`, set `$RWX_IMAGE/user` to `node` (don't run as root), `$RWX_IMAGE/command` to `node server.js`, and `NODE_ENV=production`.
- Keep build, push and test as separate embedded runs under one orchestrating run. The push run (base `rwx/base`, with `aws/install-cli`, `rwx/install-cli`, `aws/assume-role`) takes the image task ID from `tasks.build-image.tasks.image.id` and the commit SHA as the tag. This keeps push tooling and credentials out of the image. The test run pulls the image, then runs it with `docker: true`, a health check and `rwx-docker-ready-check` before the test command.
- Locked vaults: tasks don't receive the token that started the run. To push such an image, create a service account with `image:access` and `vault:unlock` for each vault used, attach it to a vault the push task can access, and set `RWX_ACCESS_TOKEN` in the push task's env.
- Account IDs, role ARN, region and registry host in the example are placeholders. Replace them.
- The guide's prose and snippet disagree on the Docker preserve option (`preserve-true` vs `preserve-data`). Check the Docker docs before using it.
- Dockerfile syntax is covered in RWX's "Migrating from Dockerfile" docs.

## Running Claude Code on RWX to open a PR

`rwx-cloud/calculator-demo` has `.rwx/claude.yml`, a run that executes Claude Code headlessly and opens a PR from the result. Shape:

- `code`: `git/clone` with `preserve-git-dir: true` so the agent can use git.
- `node`: install via `nodejs/install`, with the version from `rwx/tool-versions` reading `.tool-versions`. `node-modules`: `npm ci`, filtered on `package.json` and `package-lock.json`.
- `claude-code`: `npm install -g @anthropic-ai/claude-code`, then write `~/.claude/settings.json` (`permissions.defaultMode: bypassPermissions`) and `~/.claude.json` (`bypassPermissionsModeAccepted`, `hasCompletedOnboarding`), and set config with `claude config set -g` (autoUpdates off, notifications off, verbose).
- `claude`: `cache: false`, `timeout: 30m`. It runs `claude --dangerously-skip-permissions --append-system-prompt "Provide final result output as a pull request description." -p "$prompt"`, then `claude --continue -p` to generate a PR title. Outputs go to `$RWX_VALUES/` (`claude-result`, `pr-title`, `pr-description`), and the description includes `$RWX_RUN_URL` and the prompt. Env: `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: 1`, `CLAUDE_CODE_OAUTH_TOKEN` from a vault secret, `PROMPT_FILE: ${{ run.dir }}/prompt.md`.
- `create-pull-request`: `github/create-pull-request` with a GitHub app token, `branch-prefix: claude/${{ run.id }}`, and title and body from `tasks.claude.values`.

Bypassing permissions is only reasonable because RWX tasks are sandboxed. Keep the OAuth token in a vault, never in the repo. Pin package versions as the demo does (versions above are the demo's; check for newer).

Full file:

```yaml
base:
  os: ubuntu 24.04
  tag: 1.2

tasks:
  - key: code
    call: git/clone 1.9.5
    with:
      repository: https://github.com/rwx-cloud/calculator-demo.git
      ref: main
      preserve-git-dir: true

  - key: tool-versions
    use: code
    call: rwx/tool-versions 1.0.6
    filter: [.tool-versions]

  - key: node
    call: nodejs/install 1.1.11
    with:
      node-version: ${{ tasks.tool-versions.values.nodejs }}

  - key: node-modules
    use: [node, code]
    run: npm ci
    filter:
      - package.json
      - package-lock.json

  - key: claude-code
    use: node
    run: |
      npm install -g @anthropic-ai/claude-code

      mkdir -p ~/.claude
      cat <<'EOF' > ~/.claude/settings.json
      {
        "permissions": {
          "defaultMode": "bypassPermissions"
        }
      }
      EOF

      cat <<'EOF' > ~/.claude.json
      {
        "bypassPermissionsModeAccepted": true,
        "hasCompletedOnboarding": true
      }
      EOF

      claude config set -g autoUpdates false
      claude config set -g preferredNotifChannel notifications_disabled
      claude config set -g theme dark
      claude config set -g verbose true

  - key: gh
    call: github/install-cli 1.0.8

  - key: claude
    use: [gh, claude-code, code]
    cache: false
    timeout: 30m
    run: |
      echo "Running Claude Code..."

      prompt=$(cat $PROMPT_FILE)
      echo "$prompt"

      echo "Executing prompt..."
      claude --dangerously-skip-permissions \
        --append-system-prompt "Provide final result output as a pull request description." \
        -p "$prompt" | tee "$RWX_VALUES/claude-result"

      echo "Generating title..."
      claude --continue --dangerously-skip-permissions \
        -p "Generate a single line summary of the changes that you just made suitable for a pull request title" | tee "$RWX_VALUES/pr-title"

      echo -e "## Run\n" | tee -a "$RWX_VALUES/pr-description"
      echo -e "$RWX_RUN_URL\n\n" | tee -a "$RWX_VALUES/pr-description"

      echo -e "## Prompt\n" | tee -a "$RWX_VALUES/pr-description"
      echo "$prompt" | tee -a "$RWX_VALUES/pr-description"

      echo -e "\n## Result\n" | tee -a "$RWX_VALUES/pr-description"
      cat "$RWX_VALUES/claude-result" | tee -a "$RWX_VALUES/pr-description"
    env:
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: 1
      CLAUDE_CODE_OAUTH_TOKEN: ${{ vaults.doug_test.secrets.CLAUDE_CODE_OAUTH_TOKEN }}
      PROMPT_FILE: ${{ run.dir }}/prompt.md

  - key: create-pull-request
    call: github/create-pull-request 1.0.3
    use: claude
    with:
      github-token: ${{ github-apps.rwx-cloud-bot.token }}
      branch-prefix: claude/${{ run.id }}
      pull-request-title: ${{ tasks.claude.values.pr-title }}
      pull-request-body: ${{ tasks.claude.values.pr-description }}
```

## Why this works

- DAG-based execution and content-based caching keep reruns fast.
- CI runs without a git push/pull and without building container images, so changes validate immediately.
- Tasks are sandboxed with explicit dependencies, so an agent running locally or in the cloud needs no secrets and no up-to-date local dev environment.

The article gives no config snippets. For `.rwx/` run definitions use `rwx docs pull` (above), and confirm flags with `rwx --help` and `rwx run --help`.
