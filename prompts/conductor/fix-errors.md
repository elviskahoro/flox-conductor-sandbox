<!-- Canonical source: flox-conductor-sandbox prompts/conductor/fix-errors.md.
     Installed into a repo's .conductor settings [prompts].fix_errors by
     scripts/install-conductor-prompts.py — do not hand-edit the TOML copy.
     Companion to create-pr.md; shares its conventions (roborev gate, no AI
     attribution, no force-push). Where a repo's own instructions differ,
     the repo wins. -->

# Fixing Errors

## The principle: root cause, minimal diff, proof it's fixed

The "Fix errors" button fires when something is red: failing CI checks, a failing local build or test run, type/lint errors, or errors surfaced in the workspace. Your job is to make them green **for the right reason**.

- Fix the **cause**, not the symptom. A passing check you got by deleting the assertion, adding `# type: ignore`, loosening a lint rule, skipping a test, or catching and swallowing the exception is not a fix.
- Keep the diff **minimal and in scope**. Fix the errors that are red; don't refactor around them.
- **Prove it**: reproduce the failure first, then show the same command passes after the change.
- Never claim "fixed" without having re-run the thing that failed.

## Workflow

### Step 1: Pre-flight and scope

Run in a single batch of parallel `Bash` calls:

```bash
git status                                          # working tree clean?
git branch --show-current                           # current branch?
git rev-parse --abbrev-ref @{upstream} 2>/dev/null  # tracking ref?
git log main..HEAD --oneline                        # what is this branch?
gh pr view --json url,number,state,headRefOid 2>/dev/null   # is there a PR?
gh pr checks 2>/dev/null                            # which checks are red?
```

- Uncommitted changes you didn't make: leave them alone. Don't stash, reset, or discard them. Fold them in only if they are clearly part of the failure.
- If the branch has a PR, its failing checks are the primary error list. If there is no PR, the errors come from the user's message, the workspace error output, or a local run of the repo's build/test/lint commands.
- If there is nothing failing, say so and stop. Don't invent work.

### Step 2: Collect every error

Gather the full, actual error text — never guess from a check name.

- **CI failures:** `gh pr checks` lists them; for each failing run, `gh run view <run-id> --log-failed` gives the failing step output. Use `--job <job-id>` for a single job. Distinguish checks that *failed* from ones that were *cancelled*, *skipped*, or are still *pending* — only failures are in scope.
- **Local failures:** run the repo's own commands (look in `README`, `AGENTS.md`/`CLAUDE.md`, `Makefile`, `package.json`, `pyproject.toml`, CI workflow files under `.github/workflows/`). Run the same command CI runs, not a near-equivalent.
- **User-pasted errors:** treat as the starting point, then confirm by reproducing.

Make a short list: each distinct error, the file/line, and which check or command produced it. Group errors that share one root cause (one bad import often produces dozens of failures).

### Step 3: Triage — is it yours to fix?

Classify each error before touching code:

| Class | Signal | Action |
| --- | --- | --- |
| **Caused by this branch** | Fails on the branch, passes on `main` | Fix it. |
| **Pre-existing on base** | Also fails on `main` / unrelated files | Report it; don't fix unless the user asks. |
| **Flaky / infra** | Timeout, network error, runner crash, passes on rerun | Rerun once (`gh run rerun <run-id> --failed`); if it passes, report it as flaky. Don't "fix" code for a flake. |
| **Needs a decision** | Fix requires changing a public interface, a product behavior, or a test's intended expectation | Stop and ask. |
| **Needs access you lack** | Missing secret, permission, or external service | Say exactly what's missing; don't work around it. |

To check whether an error pre-exists, look at the latest `main` run of the same check (`gh run list --branch main --workflow <name> --limit 3`) or run the command on a clean checkout of the base.

### Step 4: Reproduce locally

Before editing, reproduce each in-scope failure with the narrowest command that shows it (a single test file, one lint rule, one type-check target). If you cannot reproduce it locally:

- Compare environment: tool/runtime versions, lockfile drift, env vars, OS differences, test ordering, timezone/locale.
- Read the CI log more carefully for what differs.
- If it still won't reproduce, report that plainly with what you tried; don't ship a speculative fix as "fixed".

### Step 5: Diagnose the root cause

Read the failing code and the code around it. State the cause in one sentence before changing anything: *"X fails because Y."* Check:

- Is the **test** wrong or the **code** wrong? Read the test's intent and the git history (`git log -p -S'<symbol>'`) before deciding which side moves. Don't edit a test to match buggy behavior.
- Did a dependency, generated file, snapshot, or lockfile drift? Regenerate with the repo's own tooling rather than hand-editing.
- Is the same defect present in sibling call sites? Fix the pattern, not one instance, when it's the same bug in the same change.

### Step 6: Fix

- Smallest change that addresses the root cause.
- Follow surrounding code style; don't reformat unrelated lines.
- Do **not**: disable or skip tests, weaken assertions, add blanket lint/type suppressions, bump timeouts to hide slowness, pin around a real incompatibility, or `--no-verify` past hooks.
- A suppression is acceptable only when the diagnostic is demonstrably a false positive; scope it to one line with a comment saying why.
- Don't touch files outside the failure's blast radius. If the real fix needs a larger change, stop and tell the user what and why.

### Step 7: Verify

- Re-run the exact command(s) that failed in Step 4 — they must pass.
- Then run the broader suite that covers the changed files (mirror source paths under `tests/`, or run the repo's full test/lint/type commands) to catch regressions your fix introduced.
- If a new, different error appears, loop back to Step 3 for it. Cap at 3 diagnose-fix-verify rounds; after that, stop and report what's still failing and what you learned.

### Step 8: Review with roborev

Roborev reviews committed history, not the working tree, and it does not run tests. So: commit first (Step 9), then:

```bash
roborev review --wait
```

- `--wait` is required — a bare `roborev review` only enqueues a background job and is not a verdict. Never report an enqueue as clean.
- Fix findings yourself without asking — **every severity counts**, low and nit included — when they are small in scope (wording, a missing guard, a rename, a missing test case, a local refactor inside the changed function). Report, with reasons, only findings that would reshape the design, change public interfaces, or touch files outside this fix's scope.
- Put fixes in a follow-up commit and re-run `roborev review --wait`. Stop after 3 fix rounds and list what remains.
- If roborev is unavailable, say so explicitly; don't silently skip.

### Step 9: Commit

Commit without asking for approval once the fix is verified.

- Stage only files that belong to the fix. Skip tool-local cruft (`.agents/`, `.claude/`, Conductor-local files).
- Message: a sentence-cased, why-focused subject naming what was broken and the cause (e.g. `Fix stale snapshot after the pagination cursor change`), plus a short body when the cause isn't obvious from the diff. No Conventional Commits prefix, matching create-pr.md.
- **No AI attribution** — no `Co-Authored-By: Claude` lines, no "Generated with" footers — per the repo's agent instructions.
- Separate commit per unrelated root cause when practical, so each is independently revertable.
- Never `--amend` or rebase commits that are already pushed.

### Step 10: Push and confirm CI

If the branch is already on `origin` (it has a PR), push the new commit(s) as a normal fast-forward:

```bash
git push
```

- **Never force-push**, `--force-with-lease` included, without explicit user approval. If the push is rejected as non-fast-forward, `git fetch` and rebase/merge per the repo's convention, re-verify (Step 7), then push — surface any conflicts to the user rather than resolving them silently.
- If the branch has no upstream and no PR, don't create one; report the fix is committed locally and let the user decide on create-pr.
- After pushing, check status once with `gh pr checks`. Don't poll in a loop: if checks are still running, say so and stop; the user can press the button again.

### Step 11: Report

Finish with a short summary the user can act on:

- **Fixed:** each error and its one-sentence root cause.
- **Verified by:** the commands re-run and their result.
- **Roborev:** clean / findings fixed / unresolved (listed) / unavailable.
- **Not fixed:** pre-existing, flaky, needs-decision, or needs-access items, each with the reason and a suggested next step.
- Commit SHA(s) and whether they were pushed.

Be factual. If a check is still red or unverified, say so; do not round up to "should be fixed".

## Anti-patterns

- **Silencing instead of fixing:** deleting/skipping tests, `@pytest.mark.skip`, `xfail`, `eslint-disable`, `# noqa`, `@ts-ignore`, `any` casts, widened types, swallowed exceptions.
- **Fixing from the check name alone** without reading the log.
- **Editing the test to match buggy output** without confirming which side is wrong.
- **Fixing on top of a guess:** shipping a change you couldn't reproduce or verify, then claiming success.
- **Scope creep:** refactors, dependency upgrades, or formatting sweeps unrelated to the failure.
- **Fixing pre-existing or flaky failures** as if the branch caused them.
- **Destructive shortcuts:** `git reset --hard`, `git push -f`, `git checkout .`, deleting lockfiles or caches to "clean up", `--no-verify`.
- **Endless loops:** more than 3 rounds without progress — stop and report instead.
- **Generated-file hand edits:** regenerate with the repo's tooling.

## Quick reference

```bash
gh pr checks                                  # what's red
gh run list --branch <branch> --limit 5       # recent runs
gh run view <run-id> --log-failed             # failing step output
gh run rerun <run-id> --failed                # rerun only failed jobs (flake check)
roborev review --wait                         # review gate (after commit)
git push                                      # fast-forward only; never -f
```
