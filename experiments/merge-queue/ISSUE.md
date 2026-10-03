# Run the GitHub merge queue experiment (and report findings)

> Hand this file to a local agent that has repo-admin credentials (a `gh` login able to write rulesets, push branches, and create/merge PRs). The cloud agent that scaffolded this could not do those steps (HTTP 403 from its proxy on ruleset writes).

## Goal

Find out, by running it, whether GitHub's **merge queue** works on `elviskahoro/flox-conductor-sandbox`, how it behaves, and what the `gh` CLI can and cannot do with it. Produce a written report of the findings.

## Background (already established)

- Merge queue is GA. It is enabled via a branch ruleset / branch protection rule ("Require merge queue"). Queued PRs are tested on a temporary `gh-readonly-queue/<base>/...` branch via `merge_group` workflow events, then merged in order.
- Availability: public repos owned by an **organization**, or private repos on Enterprise Cloud. This repo is **owned by a User account** (`owner.type == "User"`), so the queue may be **unavailable**. Confirming that is a valid, expected outcome of this experiment.
- `gh` CLI (2.89.0 checked): `gh pr merge` is queue-aware. If the base branch requires a queue and required checks passed, the PR is added to the queue; if not yet passed, auto-merge is armed; `--admin` bypasses the queue. There is **no** dedicated `gh merge-queue` command and **no REST endpoints** for queue entries. Listing/dequeuing needs GraphQL (`mergeQueue`, `MergeQueueEntry`, `enqueuePullRequest`, `dequeuePullRequest`). `gh pr merge --disable-auto` may remove a PR.

## Already in the repo (branch `claude/github-merge-queue-cli-e1xjdy`, commit `fc78ea6`)

- `.github/workflows/merge-queue-experiment.yml` - job `mq-check`, triggers: `pull_request` (paths `experiments/merge-queue/**`) and `merge_group`. Prints event context, sleeps 20s.
- `experiments/merge-queue/ruleset.json` - `merge_queue` ruleset targeting `refs/heads/mq-experiment-base` (squash, min 1 entry, wait 1 min, ALLGREEN, 5 min check timeout).
- `experiments/merge-queue/run.sh [N]` - creates `mq-experiment-base` from `main`, opens N PRs against it, runs `gh pr merge --squash --auto` on each.
- `experiments/merge-queue/README.md` - setup/run/observe notes.

## Tasks

### 0. Preflight
- [ ] `gh auth status`; confirm the token can administer the repo and write rulesets.
- [ ] `gh api repos/elviskahoro/flox-conductor-sandbox --jq '{private,owner:.owner.type,permissions}'` and record it.
- [ ] Check for existing rulesets: `gh api repos/elviskahoro/flox-conductor-sandbox/rulesets`. Do not touch any that exist.

### 1. Land the scaffolding on `main`
The workflow must exist on the base branch for `merge_group` events to trigger it.
- [ ] Open a PR from `claude/github-merge-queue-cli-e1xjdy` into `main`, review, merge it.
- [ ] Do **not** apply any merge queue rule to `main`. The experiment is scoped to `mq-experiment-base` only.

### 2. Create the throwaway base branch
- [ ] `git fetch origin main && git push origin origin/main:refs/heads/mq-experiment-base`

### 3. Create the ruleset
- [ ] `gh api -X POST repos/elviskahoro/flox-conductor-sandbox/rulesets --input experiments/merge-queue/ruleset.json`
- [ ] **Record the exact response, success or error.** If GitHub rejects the `merge_queue` rule because the repo is user-owned, capture the full error message, then try the UI (Settings > Rules > Rulesets > New branch ruleset; look for "Require merge queue"; note whether the option is shown at all) and record what you see.
- [ ] If the queue is unavailable here: **stop the run steps**, skip to Reporting, and say so plainly. Optionally repeat tasks 2-6 in an org-owned repo if the user supplies one.
- [ ] Optionally add `mq-check` as a required status check on the ruleset (add a `required_status_checks` rule with context `mq-check`) so PRs actually wait on CI before queueing.

### 4. Run the experiment
- [ ] `experiments/merge-queue/run.sh 3` (opens 3 PRs against `mq-experiment-base`, each queued with `gh pr merge --squash --auto`).
- [ ] Capture the stdout/stderr of each `gh pr merge` call. Note whether each says "added to merge queue" vs "auto-merge enabled" and when it switches.

### 5. Observe
- [ ] Poll queue state until empty:
  ```
  gh api graphql -f query='{repository(owner:"elviskahoro",name:"flox-conductor-sandbox"){mergeQueue(branch:"mq-experiment-base"){entries(first:10){nodes{position state enqueuedAt estimatedTimeToMerge pullRequest{number}}}}}}'
  ```
- [ ] `gh run list --workflow merge-queue-experiment.yml` and record, per run: event (`pull_request` vs `merge_group`), head branch (expect `gh-readonly-queue/mq-experiment-base/pr-N-<sha>`), duration, conclusion.
- [ ] Open the `merge_group` run logs and record what the "Show event context" step printed (`base_ref`, `head_ref`, `git log`) - this shows what the queue actually tests (base + earlier entries + this PR).
- [ ] Record the order PRs merged and the resulting commit history on `mq-experiment-base` (`git log --oneline origin/mq-experiment-base`). Squash merge method means one commit per PR.

### 6. Probe CLI edges
Try each and record exact output/exit code:
- [ ] `gh pr merge <n> --disable-auto` on a PR that is in the queue - does it dequeue?
- [ ] GraphQL `dequeuePullRequest` on a queued PR (get the PR node id via `gh pr view <n> --json id`).
- [ ] GraphQL `enqueuePullRequest` to re-add it.
- [ ] `gh pr merge <n> --admin` on a PR targeting the queue branch - does it bypass the queue?
- [ ] `gh pr checks <n>` and `gh pr view <n> --json mergeStateStatus,autoMergeRequest` while queued - does `gh` surface queue state anywhere? (`gh pr status`, `gh pr list --json`)
- [ ] Failure path: add a commit to one PR (or temporarily change the workflow to `exit 1` on a marker file) so its `merge_group` check fails. Record how the queue handles it: is that PR ejected, do later entries rebuild, how is it reported.
- [ ] Concurrency: confirm whether entries are tested in parallel (`max_entries_to_build`) with each build including earlier entries.

### 7. Cleanup
- [ ] Close any remaining experiment PRs; delete `mq-exp-*` branches and `mq-experiment-base` (`git push origin --delete ...`).
- [ ] Delete the ruleset: `gh api -X DELETE repos/elviskahoro/flox-conductor-sandbox/rulesets/<id>`.
- [ ] Leave `main` and its settings unchanged. Do not leave any merge queue rule active.

## Safety constraints
- Only touch `mq-experiment-base`, `mq-exp-*` branches, the `mq-experiment` ruleset, and the experiment PRs. Never apply rules to `main`.
- Do not use `--admin` on `main`-targeting PRs.
- Everything created must be removed in task 7 unless the user says to keep it.

## Deliverable
Write `experiments/merge-queue/FINDINGS.md` and commit it on a new branch (open a PR to `main`). Include:
1. **Availability verdict**: is merge queue usable on this user-owned repo? Exact error/UI evidence.
2. **Behavior observed**: timeline of PRs/runs, `merge_group` branch naming, what the queue branch contained, merge order, timing.
3. **CLI matrix**: for each operation (enqueue, auto-merge, dequeue, list entries, bypass, status), what worked via `gh pr ...`, what needed `gh api graphql`, what was impossible. Include exact commands and outputs.
4. **Failure-handling behavior** from task 6.
5. **Gotchas / surprises**, and a recommendation on whether to adopt merge queue and with which settings.
6. **Cleanup confirmation**: list of what was deleted.

## Acceptance criteria
- [ ] Verdict on availability is stated with evidence.
- [ ] If available: 3 PRs were queued and merged through the queue, with `merge_group` run evidence.
- [ ] CLI matrix is complete (or each gap marked as "blocked because ...").
- [ ] `FINDINGS.md` is committed and a PR is open.
- [ ] All experiment resources are cleaned up and `main` is untouched aside from the scaffolding PR.
