<!-- Canonical source: flox-conductor-sandbox prompts/conductor/create-pr.md.
     Installed into a repo's .conductor settings [prompts].create_pr by
     scripts/install-conductor-prompts.py — do not hand-edit the TOML copy.
     Upstream history: gtm-sdk prompts/conductor/create-pr.md (incl. #921).
     Repo-specific references (Linear, design/ artifacts,
     roborev) follow the cross-repo conventions — where a repo's own
     instructions differ, the repo wins. -->

# Creating Pull Requests

## The principle: why over what

A PR description's job is to give the reviewer what the diff *can't*: motivation, alternatives considered, risks worth scrutinizing, and a trail back to the originating context. The diff itself is the source of truth for what changed — paraphrasing it in the description is duplicate work that rots the moment someone force-pushes.

Concretely:

- Lead with the **problem**, not the change.
- Name the **alternatives** you considered, briefly. Skip if there were no meaningful ones.
- Call out what reviewers should **scrutinize**, not what they should take on faith.
- Link the **breadcrumb trail** — Linear ticket, design spec/plan, predecessor PR.
- **Never** summarize the diff. The reviewer is about to read it.

A reader who skims your description should walk away with the mental model needed to read the diff with intention.

## Workflow

### Step 1: Pre-flight checks

Helper `pr-preflight` first refreshes the remote refs and stops if that fails.

This workflow expects `origin` to contain the PR base branch. In fork workflows, configure the base repository as `origin` and the branch's push repository as another remote. If the base is not available at `origin/<base>`, stop and surface which remote should serve as the base; do not guess.

If `pr-preflight` exits nonzero or prints a stop condition, stop the workflow even if the other parallel checks completed.

Run `git status`, `git branch --show-current`, and helper `pr-preflight` as one parallel batch. `pr-preflight` refreshes `origin`, resolves publication, base, open-PR head, and push target, prints a labeled `PR preflight:` line (record its values for later steps), then shows redacted remotes, commits beyond the base, and the diff stat. It exits nonzero with the reason on stderr for any stop condition.

Stop and surface the problem to the user if any of these is true:

- The working tree has uncommitted changes — ask the user whether to commit, stash, or abandon.
- A selected-upstream or open-PR-head lookup fails — stop; do not treat it as absent. For other configured remotes, disable terminal prompts with `GIT_TERMINAL_PROMPT=0`. If a remote is unreachable but another lookup identifies the branch or the open PR identifies the push target, report the failed lookup as a warning and require explicit approval of any target not identified by the upstream or PR. If no lookup identifies a target, stop and surface the ambiguity before changing history or pushing. If `gh pr view` fails, list candidate PRs for the branch with their head repository and compare owner, repository, and branch to the resolved push target; do not stop for an unrelated fork with the same branch name. Do not parse human-readable error text. For a new branch with multiple remotes and no existing push target, ask which remote to use; do not default to the base repository. If a remote URL cannot be mapped (including GitHub Enterprise paths), ask the user to confirm the push remote and `<owner>:<branch>` PR head; do not guess. Resolve `insteadOf` rewrites with `git ls-remote --get-url` before mapping.
- A branch that only tracks the base is unpublished unless an open PR or same-named remote branch proves otherwise; never push to the base. If its configured upstream points to a differently named remote branch, preserve history, show the exact destination in the preview, and wait for the user's explicit confirmation before pushing there.
- A same-named remote branch found without a configured non-base upstream or matching open PR is evidence that history may already be published, but does not establish that remote as the intended push target. Preserve history, show the exact candidate remote/ref, and require the user's explicit approval of that target in the Step 8 preview before pushing.
- The branch has zero commits beyond the base — there's nothing to PR.
- An open PR already exists for this branch — use `gh pr edit` to update it, not `gh pr create`. If the branch has a closed or merged PR, stop and offer a new branch name or ask for explicit confirmation before opening a new PR from the same head.

Don't paper over these by force-pushing, amending, or running `git push -f`. The repo's agent instructions (AGENTS.md/CLAUDE.md) apply: destructive operations need explicit user approval.

### Step 2: Gather context for the "Why"

A strong Why section comes from upstream artifacts, not from the diff. Pull from these sources in parallel where possible:

**Linear ticket** — if the branch name matches `(feature|agent)/<team>-<number>-<slug>` (e.g., `feature/ai-268-foo`, `agent/eng-1234-bar`):

1. Extract the ticket ID with a regex like `[A-Z]+-\d+` (case-insensitive).
2. Read it via `mcp__linear__get_issue` with the identifier.
3. Lift the problem statement and acceptance criteria into the Why section — **paraphrase, don't paste**. A wall of quoted ticket text isn't a PR description.
4. Save the URL for the Links section.

Skip the Linear lookup when the repo doesn't use Linear (no Linear MCP configured, no matching branch pattern) — rely on the sources below.

**GitHub issue** — if the user linked or named a GitHub issue this session (a URL, `#NNN`, or an issue the branch was created for, e.g., `conductor/gtm-sdk-issue-608`):

1. Note whether it's same-repo or cross-repo (a bare `#NNN` or number is same-repo; a URL or `owner/repo#NNN` names the repo explicitly — keep that `owner/repo` around for every later step). Fetch it with `gh issue view <number>` for a same-repo issue, or `gh issue view <number> --repo <owner/repo>` otherwise, to confirm it's still open and pull the problem statement into the Why section — paraphrase, don't paste.
2. Ask yourself (and, if unclear, the user) whether this PR **fully** resolves the issue or only partial work. Carry that determination into Step 7's Links section and Step 9.
3. Save the issue reference for the Links section either way.

**Design artifacts** — scan `design/` (when the repo uses the design-artifact convention) for backlog/done files matching the branch topic:

```bash
ls "$(git rev-parse --show-toplevel)/design/" 2>/dev/null | grep -iE "<topic-keyword>"
```

- `*-spec-*.md` files carry motivation, constraints, trade-offs.
- `*-plan-*.md` files carry scope (and by elision, what's out of scope).
- Read the matching artifact in full before drafting.

**Git history**:

- `git log "origin/<confirmed-base>"..HEAD --format='%s%n%b%n---'` — commit subjects and bodies often capture in-flight decisions better than the final diff.

**Current conversation**:

- If the user discussed alternatives, made decisions mid-flight, or set constraints earlier in this session, those belong in Trade-offs or Risks.

If none of these sources establishes a clear Why, **stop and ask the user**. Don't fabricate motivation — a confident-sounding-but-vague Why is worse than asking.

### Step 3: Commit local changes

If the pre-flight check surfaced uncommitted changes that belong in this PR, commit them **before** running roborev — roborev reviews committed history, not the working tree, so uncommitted edits would be invisible to it.

- Stage only the files that belong in this PR. Skip tool-local cruft (e.g., `.agents/`, `.claude/`, Conductor-local files) unless the user explicitly opts in.
- Commit without asking for approval: run `git commit` directly once the files are staged. The commit message should mirror the PR title's intent (sentence-cased, why-focused) — not a Conventional Commits subject. The Step 8 draft approval is still the only user-approval gate before push.
- Do **not** push yet. Push happens in Step 11, after squash, roborev, the user-confirmation gate, and the rebase.

If the working tree is already clean, skip this step.

### Step 4: Squash to a coherent set of commits

**Hard gate for unpublished branches: squash before roborev, roborev before the user-confirmation gate, confirmation before push.** A branch is published if an open PR exists, a same-named branch exists on any configured remote, or its configured upstream points to an existing non-base branch. A local branch that only tracks the base branch (for example, `origin/<confirmed-base>`) is still unpublished. Check these in Step 1; commits on `origin/<confirmed-base>` alone do not make this branch published. On a published branch, preserve history: commit fixes as follow-ups, review that exact history, and never rewrite or force-push it.

```bash
git log "origin/<confirmed-base>"..HEAD --oneline
```

- **Default to one commit per new, unpublished PR branch.** Multi-commit PRs are only OK when each commit is independently reviewable and the slices land in order. This default does not authorize rewriting a published branch.
- Squash an unpublished branch from its merge base with `git reset --soft "$(git merge-base origin/<confirmed-base> HEAD)"` followed by `git commit`. This keeps newer base-branch commits out of the squash; Step 10 rebases onto the latest base afterward. Do not suggest an interactive rebase in non-interactive workspaces. Never use `--no-edit` flags that bypass message review.
- The squashed commit message mirrors the PR title's intent (sentence-cased, why-focused) and captures the motivation in the body. No Conventional Commits prefix.
- If the branch already has a single commit (or each existing commit is independently reviewable and ordered), skip the rebase but still confirm the count before moving on. If the branch is already published, preserve its history and use follow-up commits for review fixes; note the multi-commit history in the Step 8 preview.
- **Never force-push to a shared branch to squash after publication.** Squash *before* the first push.

### Step 5: Run relevant tests locally, then roborev review before drafting

**Roborev reviews the diff; it does not execute the test suite.** A clean roborev pass says nothing about whether the code runs — it has caught logic/quality issues while a hardcoded assertion in a test file was still broken. Before roborev, run whatever tests cover the changed files:

- Identify affected tests by mirroring the changed path under `tests/` (many repos mirror source layout — a change to `pkg/foo.py` often has a matching `tests/.../test_foo.py`) and/or `grep -rn` the changed file's distinctive strings (a literal like an `if:` condition, a flag name) across `tests/` to catch assertions on exact values.
- Run the narrowest test target that covers the change (in a uv-based Python repo, `uv run pytest tests/<mirrored-path>`; otherwise the repo's own test command) — full-suite runs are fine too, but don't skip this step because CI will "catch it anyway": local runs take seconds, CI takes minutes.
- If a test fails, fix it now and fold the fix into the same commit (Step 3/4), *before* running roborev — don't push and let CI discover it.

**Hard gate: do not draft the PR or move toward `git push` until roborev has run and either reported clean or been explicitly acknowledged by the user.** This applies even if the change feels trivial, even if the diff is one line, and even if the user has not asked for review explicitly — the skill always runs roborev before the user is asked to approve a draft.

With the squashed commit in place but the branch still local, run a local AI code review with roborev so findings surface *before* the user sees a draft and *before* GitHub sees the diff. Invoke the `roborev` executable directly with the `--wait` flag; Git aliases are optional conveniences and may not exist in cloud sandboxes:

```bash
roborev review --wait
```

- `--wait` is **required**, not optional — it blocks until the review completes so findings are available before the draft is shown. Do not run `roborev review` without `--wait`.
- A bare `roborev review` — or a leftover post-commit auto-review hook — only **enqueues a background daemon job and returns before a verdict exists**. An enqueue is not a pass: if HEAD already has a queued or running background review, block on it (`roborev review --wait`, or `roborev wait` for the already-enqueued job) so an actual verdict is in hand before drafting. Never report "review enqueued" or a missing verdict as clean.
- Capture the outcome as `clean after M fix rounds`, `findings remain (N)`, or `unavailable (reason)`. Parked findings count as findings that remain. Step 8 uses the same status vocabulary and lists unresolved, parked, and out-of-scope findings in its separate findings section.
- **Review loop:** follow the shared Roborev policy in General Preferences, which Conductor appends to every agent session. After each finding batch, commit fixes and re-squash an unpublished branch per Step 4 before rerunning review. If the branch is already published, keep follow-up commits, preserve their history, and squash at merge instead of rewriting or force-pushing. For a published branch, note the extra commits in the Step 8 preview. Ask the user as soon as a finding requires a major architecture/refactor, public-interface change, product/design decision, or scope expansion. Continue with independent findings while waiting, but do not draft or seek publication approval while a required decision is pending. If the user declines the change, record that finding as parked or out of scope and include it in the Step 8 preview; if they approve, make the change and review it. Show every remaining, parked, and out-of-scope finding in the preview; parked and out-of-scope findings do not count as clean. The user's approval of that preview acknowledges the listed findings, so do not ask twice. Push only after a clean review or that explicit preview approval.
- If General Preferences is absent, keep fixing actionable findings with no round or per-finding cap until resolved or blocked by a major architecture/refactor, interface/product decision, or scope boundary. Report progress after each pass; ask about blockers and continue with other findings. If Roborev is unavailable, say so and ask whether to proceed.
- For deeper fix/refine loops, consult the repo's roborev guide skill if it ships one.

### Step 6: Draft the title

The title is a formal, sentence-cased statement of **why this change exists** — not a conventional commit subject. A reviewer scanning the PR list should understand the *motivation*, not just the area of code touched.

Rules:

- **Formal, sentence case.** "Eliminate duplicated Attio retry logic across five call sites" — not "attio retry refactor".
- **Lead with the why, not the what.** Prefer the problem solved or the outcome enabled over the mechanical change. "Unblock Linear → Attio sync from rate-limit drift" beats "Add retry decorator to Attio client".
- **No Conventional Commits prefix.** Do **not** use `feat:`, `fix:`, `refactor:`, `chore:`, `docs:`, etc. Even if recent commits or PRs use them, PR titles in this ecosystem are full sentences. Commit messages and PR titles are different surfaces.
- **Under 70 characters where possible**, but clarity wins over brevity — GitHub truncates in list views, so front-load the most important words.
- **Specific.** "Fix off-by-one in Apollo pagination cursor causing missed contacts" — not "Bug fix" or "Improvements".
- **No ticket IDs in the title.** They go in Links.
- **No trailing period.**
- **Avoid bare imperative verbs** like "Add", "Fix", "Update" as the first word when a why-framing is possible. They're allowed when the why genuinely is the action (e.g., a clear bugfix), but check first whether the motivation can lead instead.

Good vs. bad title shapes:

| Bad (conventional / what-focused) | Good (formal / why-focused) |
| --- | --- |
| `feat: add retry decorator` | `Consolidate Attio retry logic to unblock Linear sync` |
| `fix: pagination bug` | `Fix off-by-one in Apollo pagination cursor causing missed contacts` |
| `refactor: clean up attio client` | `Eliminate divergent retry behavior across Attio call sites` |
| `chore: bump deps` | `Bump httpx to 0.27 to pick up the connection-pool leak fix` |

### Step 7: Draft the description

Use this template. **Drop sections that have nothing meaningful in them** — a section containing "None" or "N/A" is worse than no section.

```markdown
## Why
<1-3 paragraphs. Lead with the problem or constraint. State the motivation. Reference upstream context (ticket, spec) by link, not paraphrase. The reviewer should finish this section understanding what would happen if the PR were *not* merged.>

## Trade-offs
<Only if there were meaningful alternatives. Format: "Chose X over Y because Z." Skip if the approach was obvious or there was only one reasonable way.>

## Risks
<What could break that isn't already covered by tests. Note rollback path if non-trivial. Skip for clearly low-risk changes (docs, comments, isolated refactors with full coverage).>

## Test plan
<Reasoning, not output. "Exercised X path with Y inputs because Z is the highest-risk surface." If full unit coverage exists and the change is small/obvious, skip this section.>

## Links
- Linear: [TEAM-NNN](https://linear.app/...)
- Spec: design/backlog-...-spec-01.md
- Plan: design/backlog-...-plan-01.md
- Related PRs: #NNN
- Closes #NNN (only when Step 2 confirmed this PR fully resolves a same-repo GitHub issue)
```

Section guidance:

| Section | Required? | When to drop it |
| --- | --- | --- |
| Why | Always | Never. If you can't write a specific one, the work isn't ready. |
| Trade-offs | When meaningful alternatives existed | Obvious one-way changes, fixes to clear bugs |
| Risks | When the change has non-trivial blast radius | Docs, comments, isolated refactors with coverage |
| Test plan | When testing required judgment calls | Small changes with full unit coverage |
| Links | If any upstream artifact exists | True greenfield work with no ticket, spec, or predecessor PR |

### Step 8: Show the draft. Wait for confirmation. (Single publication approval gate before push.)

**This is the only user-approval gate for publishing the PR, and it sits immediately before `git push`.** If a later base-update review changes the findings, show the updated preview and obtain approval here again before pushing. Any major architecture, interface, product/design, or scope decision raised by Roborev must already be resolved before drafting; the publication preview is not a substitute for that decision. Steps 3–5 (commit, squash, roborev) must already be complete by the time you reach it — by construction the agent cannot honor a "yes" without having walked the roborev gate first.

Show the draft title, the draft body, the roborev outcome, the exact push remote/ref, whether that destination needs explicit confirmation, and all unresolved, parked, and out-of-scope findings so the user can see the gate was walked. Parked and out-of-scope findings do not count as clean. The user's approval of this complete preview acknowledges every listed finding and confirms any push target marked as requiring explicit confirmation; do not ask for a second acknowledgment. Even if the user said "create a PR", they agreed to the action, not blind-trusted your draft.

**Shortcut:** If the user re-sends this *exact* create_pr prompt verbatim, or an explicit approval phrase like "create/open the PR now," immediately after the agent has already shown a draft under this step, treat that as the Step 8 approval only when the preview lists no unresolved, parked, or out-of-scope findings. When findings are listed, the reply must explicitly accept the listed findings and request that the PR proceed; a verbatim prompt resend or "create the PR now" alone is not enough. A revision request or question is not approval; treat it as normal feedback and re-show the draft.

Format the preview as:

```text
Title: <draft title>

Body:
---
<draft body>
---

Roborev: <clean after M fix rounds | findings remain (N, including parked findings) | unavailable (reason)>

Push target: <remote>:<ref> (PR head: <owner>:<branch>; confirmation required: yes/no)

Unresolved / parked / out-of-scope review findings: <none | list every finding and any user decision>

Published branch history: <unpublished | published; preserved follow-up commits; open PR: <none | URL>>

Next action: <push and create PR | push follow-up commits and create PR | push follow-up commits and update existing PR>

Proceed with this action? (or edit before I submit)
```

The roborev line is mandatory — never omit it. If it shows "unavailable", the user is implicitly being asked to proceed without review.

If the user requests edits, revise and re-show. Don't auto-submit. A "yes" here authorizes closing or linking the GitHub issue (Step 9), the appropriate base update (Step 10), the push (Step 11), and either PR creation or update (Step 12) — proceed through all of them without re-prompting (pausing only if the rebase or merge hits conflicts).

### Step 9: Note the GitHub issue disposition

If Step 2 identified a GitHub issue this PR addresses, carry its disposition forward — the actual action happens in Step 12b, once a PR URL exists:

- **Same-repo issue, fully resolved by this PR** — the `Closes #NNN` line already lives in the PR body (Step 7's Links section). Nothing further is needed here: GitHub auto-closes the issue when the PR merges into `<confirmed-base>`. Don't `gh issue close` it now — the fix isn't on the base branch yet.
- **Cross-repo issue, or only partially resolved** — GitHub's closing keywords don't work across repos and shouldn't be used for partial work. Remember to leave a linking comment in Step 12b instead of closing it.
- **Ambiguous whether this PR fully resolves it** — this should already have been resolved in Step 2; if it wasn't, ask the user now rather than guessing at merge-closing behavior.
- Skip silently if no GitHub issue was identified in Step 2.
- Already authorized by the Step 8 "yes" — don't re-prompt.

### Step 10: Update against the latest base without rewriting published history

For an unpublished branch, rebase onto `origin/<confirmed-base>` so conflicts surface locally before the first push. For a published branch, preserve its history: do not rebase. If it needs the latest base, merge `origin/<confirmed-base>` into the branch; otherwise skip this step. After any rebase or merge, run the relevant checks and `roborev review --wait` on the updated history before pushing. If that review finds issues, follow the Step 4–5 fix, squash, and review loop for unpublished branches or preserve follow-up commits for published branches. If the review changes the findings or push destination shown in Step 8, re-show that preview and wait for approval before pushing. This is the final step before pushing.

Rebasing a branch that is already on a remote would rewrite published history and require a force-push, which is forbidden without explicit user approval.

Run `git fetch origin` (stop if it fails), then `git rebase origin/<confirmed-base>` for an unpublished branch, or `git merge origin/<confirmed-base>` for a published branch that needs a base update.

- If the rebase or merge is clean, run the required checks and review, then proceed to Step 11 if the Step 8 preview remains accurate. If it hits conflicts, **stop and surface them to the user.** Resolve them (or have the user resolve them), then rerun the relevant checks and `roborev review --wait` so the review reflects the updated history. Never skip or abandon conflicting changes silently.
- If no base update is needed, proceed to Step 11.

### Step 11: Push the branch

Once the rebase or merge is clean, rerun Step 1's compound target-resolution check. Copy its freshly printed `push_remote`, `push_ref`, and `push_head` values into the commands below; variables from Step 1's subshell do not persist. Confirm the values match the approved Step 8 preview. If `push_confirmation=yes`, the user's approval of that preview is the required explicit confirmation. Never push to the base branch. Set upstream tracking when no usable non-base upstream exists, including when the configured remote branch is stale.

Run helper `push` with the confirmed base and the fresh `push_remote` and `push_ref`. It refuses placeholders and the base branch, verifies the configured upstream, and pushes to `HEAD:<push_ref>` (adding `-u` when no usable non-base upstream exists).

Confirm the push succeeded before moving on. If it fails (auth, protected branch, non-fast-forward), surface the error and stop — do not force-push.

### Step 12: Create or update the PR

If Step 1 found an open PR for this branch, update it with `gh pr edit <number> --title ... --body ...`; do not run `gh pr create`. If no open PR exists, create one with `gh pr create --base <confirmed-base> --head <push_head>`. Draft the final body and verify its issue-closing keywords before either command. `push_head` is derived from the exact push remote and ref in Step 1; passing it explicitly avoids GitHub CLI guessing the head when multiple remotes are configured. This includes a published branch that has no open PR.

**Hard gate before running `gh pr create` or `gh pr edit`: for every same-repo GitHub issue Step 2 determined this PR fully resolves, mechanically verify the final body contains a `Closes #NNN` / `Fixes #NNN` / `Resolves #NNN` line for *that specific* issue number before shelling out — one PR can fully resolve more than one issue, and each needs its own closing reference, not just the first.** This is a real known failure mode, not a hypothetical: gtm-sdk#609 was fully fixed by gtm-sdk#628, but the drafted body only listed "gtm-sdk#609" under Links without a closing keyword, so GitHub never auto-closed it and it sat open until manually closed later. A "the plan said to add it" belief is not sufficient — grep the exact `PR_BODY` that will be sent by either command once per fully-resolved issue number:


`\b` is not portable to the BSD `grep` on macOS — use the `([^[:alnum:]_]|$)` form above instead, which matches the same "word boundary or end of string" intent on both BSD and GNU grep.

If that grep fails for any fully-resolved issue number, **stop and fix the body** — don't proceed to create or edit a PR with a body that silently downgraded to a bare reference. If Step 2 flagged partial/cross-repo instead, the grep is expected to fail and that's correct — don't add the keyword in that case.

To make this checkable, assign the HEREDOC to `PR_BODY` first, grep that exact variable, then pass it to `--body` — don't construct the body inline in the `gh pr create` call, since there's nothing to grep before shelling out:

Write the final body to a file (real newlines, not `\n`), then run helper `pr-submit` with: confirmed base, `push_head`, the open PR number from preflight (or `none`), the title, the body file, and every fully-resolved issue number. The helper rejects placeholders, fails if any listed issue lacks its closing keyword, and then runs `gh pr create` or `gh pr edit`.

Return the PR URL to the user. Don't add follow-up commentary unless the user asks — the URL is the work product.

### Step 12b: Link the GitHub issue, if Step 9 deferred it

Only applies when Step 9 flagged a **cross-repo or partially-resolved** issue — the fully-resolved same-repo case already carries its `Closes #NNN` in the PR body and needs no action here.

```bash
gh issue comment <number> --body "Addressed in <PR URL from Step 12>"                    # same-repo, partial
gh issue comment <number> --repo <owner/repo> --body "Addressed in <PR URL from Step 12>" # cross-repo — use the owner/repo saved in Step 2
```

- `<PR URL>` is the output from Step 12 — this step cannot run before Step 12 for exactly that reason.
- Do not close the issue yourself; partial or cross-repo work isn't the maintainer's signal to close it.
- Skip silently if Step 9 found nothing to do here.

### Step 13: Suggest the merge once tests and checks pass

Merging is never automatic. Once the PR is open, check its status with a single call (`gh pr checks <pr-number>`). When tests and required checks have passed, suggest merging with the GitHub CLI and wait for the user to say yes:

```bash
gh pr merge <pr-number> --squash
```

- Do not poll in a loop. If checks are still running, report that and stop; the user can ask again later.
- Do not log in to, configure, or call any merge-queue service. If `gh` is not authenticated, say so and stop.
- Never pass `--admin` or `--auto` unless the user asks for it.

## Modifiers: drafts, reviewers, labels

`gh pr create` accepts modifiers that don't affect the description but matter for the PR's lifecycle. Don't auto-set any of these; only pass what the user explicitly asks for:

| Flag | When |
| --- | --- |
| `--draft` | User says "draft", or commit history shows clear in-progress markers ("WIP", "spike"). |
| `--reviewer <handle>` | Only when the user names reviewers. Don't guess. |
| `--label <name>` | Only labels that exist (`gh label list`). Invented labels silently no-op. |
| `--assignee <handle>` | Default to `@me` unless told otherwise. |
| `--base <branch>` | Only override the default branch when the user says so. |

## Anti-patterns

These show up in autogenerated PR descriptions and this skill must actively avoid them. Several come from defaults baked into other tools — including the default `gh pr create` template suggested by the Bash tool — and this skill overrides them.

### Don't summarize the diff

```markdown
## Summary
- Added `retry_with_backoff` helper in `apollo/client.py`
- Updated `enrich_account` to use it
- Added 3 unit tests in `test_apollo.py`
```

The reviewer is about to read the diff. This is duplicate work that rots the moment the diff changes. Replace with **Why**.

### Don't write empty sections

```markdown
## Risks
None.

## Test plan
Tested locally.
```

"None" and "Tested locally" carry zero signal. Drop the section.

### Don't add AI attribution

The repo's agent instructions (AGENTS.md/CLAUDE.md) prohibit AI attribution in commits and PRs.
**Never** emit:

- `Co-Authored-By: Claude <claude@anthropic.com>`
- `🤖 Generated with [Claude Code](...)`
- Any "Generated by ..." or "Powered by ..." footer

The Bash tool's default PR template includes the 🤖 footer. **Strip it.** This skill overrides that default.

### Don't restate the title

If the title is "Fix race in Apollo enrichment dedup", the description shouldn't open with "This PR fixes a race in the Apollo enrichment dedup logic." Start the Why with the problem, not a rephrase.

### Don't pad with boilerplate

- "This PR makes some improvements to ..."
- "As discussed offline, ..."
- "Cleaning up some technical debt ..."

If you can't write a specific Why, pause and ask the user. Vague motivation is a tell that the work isn't ready for review.

### Don't paste test output

The Test plan section is about the *reasoning* behind what was tested. A reviewer can run the tests. They cannot rederive your reasoning from the output.

### Don't include "Closes #NNN" without confirming

GitHub auto-closes referenced issues on merge. Only use `Closes` / `Fixes` / `Resolves` keywords if Step 2 confirmed the PR fully resolves a **same-repo** issue. For partial work or a cross-repo issue, mention it in Links instead and leave a linking comment on the issue in Step 12b — no magic keyword. Skipping the confirmation in Step 2 is a bug, not a safe default: it leaves the issue open with no trace back to the PR that addressed it.

### Don't autopilot the PR submission

Even if the user said "create a PR for this", they agreed to the action, not to a specific draft. Show the draft, wait for confirmation, then submit.

## Examples

### Example 1: Small bug fix — Why + Links only

**Title:** `Fix off-by-one in Apollo pagination cursor causing missed contacts`

**Body:**

```markdown
## Why
The Apollo `search_people` paginator was dropping the last page of results because the cursor check used `>` instead of `>=`. Affected every batch where total results were an exact multiple of page_size — roughly 10% of runs. Caught when a TAM build was missing ~50 known contacts ([AI-1234](https://linear.app/...)).

## Links
- Linear: [AI-1234](https://linear.app/...)
```

(Trade-offs, Risks, Test plan dropped — small obvious fix, full coverage exists.)

### Example 2: Refactor — Why + Trade-offs + Risks + Links

**Title:** `Consolidate Attio retry logic to unblock Linear → Attio sync`

**Body:**

```markdown
## Why
Five call sites in `libs/attio/` were duplicating retry/backoff logic, and each had drifted: `update_person` retried on 5xx but not 429; `create_person` retried on 429 but with no backoff; `list_workspaces` did no retry at all. The new Linear → Attio sync was about to become the sixth divergent copy.

Pulling the logic into `@retry_with_backoff` lets callers opt in with one line and ensures consistent behavior across all Attio writes.

## Trade-offs
Considered `tenacity` instead. Rejected because the call sites already have idiosyncratic logic — custom backoff that respects Attio's `Retry-After` header — that `tenacity` would require a custom wait strategy to express. The hand-rolled decorator is ~30 lines and stays close to the Attio-specific behavior.

## Risks
Changes the *shape* of exceptions that bubble up: `AttioRateLimit` is now wrapped in `RetryExhausted` after N attempts. Two existing callers caught `AttioRateLimit` directly; both updated in this PR. Grep for `AttioRateLimit` returns no other matches.

## Links
- Linear: [AI-2891](https://linear.app/...)
- Spec: design/backlog-202604010000-attio_retry_decorator-spec-01.md
```

### Example 3: Bad → Good

**Bad:**

```markdown
## Summary
- Added retry decorator
- Updated 5 Attio call sites
- Removed duplicate retry code
- Added tests

## Test plan
- [x] Ran tests
- [x] Tested locally

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

What's wrong: the Summary paraphrases the diff, the Test plan has no reasoning, the AI footer is forbidden, and there's no motivation a reviewer can use to evaluate the change.

**Good:** see Example 2.

## Failure modes and recovery

| What happened | What to do |
| --- | --- |
| Linear MCP unavailable or ticket not found | Continue without the Linear context. Note in Links: "Linear ticket: AI-NNN (MCP unavailable at draft time)" and let the user fill in. |
| Branch doesn't match a Linear pattern | Skip the Linear lookup. Rely on design artifacts and conversation. |
| No design artifact, no ticket, no clear Why from the conversation | Stop. Ask the user: "I can't establish a specific Why for this PR from the available context. Can you summarize the motivation in 1-2 sentences?" |
| `gh pr create` fails (auth, network, no remote) | Surface the error to the user. Don't retry without diagnosing. |
| User rejects the draft | Take their feedback and rewrite. Don't argue. |
| User wants to skip the confirmation step | Honor it — but require an explicit "skip confirmation" or "just create it" from them. Default is to confirm. |

## Common pitfalls

| Pitfall | Why it bites | Fix |
| --- | --- | --- |
| Drafting before pre-flight checks | PR opened against stale base, with uncommitted work left behind | Run the pre-flight batch first |
| Not checking for an existing PR | Duplicate PR, or `gh pr create` errors out | Always `gh pr view` first |
| Pasting the Linear ticket verbatim | Description becomes a wall of duplicated text | Paraphrase the problem statement; link the rest |
| Filling all sections regardless of signal | Skim-defeating filler | Drop sections that don't carry meaning |
| Autopiloting `gh pr create` | Premature publication; harder to retract than to delay | Show draft, wait for confirmation |
| Inheriting the default 🤖 footer | Violates the repo's no-AI-attribution rule | Strip it from the body |
| Trusting a clean roborev as proof the code runs | Roborev reviews the diff, not test execution — a hardcoded test assertion (e.g. a literal YAML `if:` string) can still fail in CI | Run the mirrored test file / grep for affected literals before roborev (Step 5) |
| Using "WIP" in title instead of `--draft` | Title noise; doesn't actually mark the PR as draft | Use `gh pr create --draft` and a clean title |
| Linking to the PR's own branch name as "context" | The branch is implicit; this is noise | Only link to artifacts that aren't already obvious from the PR |
| Forgetting the linked GitHub issue entirely | Issue lingers open after merge with no trace back to the PR that fixed it | Resolve it in Step 2, `Closes #NNN` in Step 7, record disposition in Step 9, comment in Step 12b |
| Drafting `Closes #NNN` in Step 7 but the final body sent to `gh pr create` drops it (edits, re-drafts, template drift) | Issue never auto-closes even though Step 2/9 correctly flagged full resolution — happened for real on gtm-sdk#609/#628 | Step 12's mechanical grep gate on the literal `--body` string, not on what Step 7 intended to write |

## Red flags (stop and rethink)

- **About to `git push` without running `roborev review --wait` first.** This is the repository-wide roborev gate defined in the repo's agent instructions; no PR should skip it.
- **About to `git push` with more commits than the PR needs.** Squash to a coherent set first (Step 4); don't rely on GitHub's "Squash and merge" button to clean up history before review.
- Drafting a PR with no Linear ticket, no design artifact, and no conversation-derived motivation.
- Writing more than 3 paragraphs in Why. If you need that much, the work is probably two PRs.
- Including a `## Summary` section. This is the default template's tell — replace with `## Why`.
- Including a 🤖 footer.
- More than 5 bullets in any one section. Each bullet should be load-bearing.
- A title that ends in a period, or starts with "Update", "Fix some", "Misc", "Various".
- A title that uses a Conventional Commits prefix (`feat:`, `fix:`, `refactor:`, `chore:`, `docs:`). PR titles are formal sentences, not commit subjects.
- A title that describes *what* the diff does (e.g., "Add X helper", "Refactor Y module") when a *why* framing was available.
