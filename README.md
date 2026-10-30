# flox-conductor-sandbox

Lightweight software for a developer who works alone and runs a lot of AI
coding agents at once.

## Why this exists

When you build software alone, you do every job yourself. You write the code,
review it, run the infrastructure, triage the bugs, and ship the releases. AI
coding agents change that. You can now hand work to five or ten agents at
once, each in its own cloud workspace. But each of those workspaces starts as
a blank machine, and each agent starts with no memory of what the others
learned. Without some structure, you end up as the glue: relaying CI logs,
re-explaining the same pitfalls, and checking whether each workspace has the
right tools.

Larger teams have people whose whole job is keeping all of this consistent.
A solo developer doesn't, and shouldn't need them. This repo is the small,
boring layer that takes on that role. Every workspace starts the same way,
every change gets reviewed, and what one agent learns is there for the next
one. That way your attention goes to the work instead of the plumbing.

## How a change moves through it

Each step exists to take one job off your plate.

1. **[Detail](https://detail.dev) finds the bugs.** It clones the repo into
   its own sandbox, exercises the code, and keeps only the small share of
   findings most worth caring about. Each one comes back as a pull request
   with a fix, or as a ticket. Bugs get found without depending on you, a
   user, or production noticing them first.
2. **An agent works on it in a
   [Conductor cloud workspace](https://www.conductor.build/docs/cloud).**
   Every task gets its own Linux sandbox, built from one shared setup, with
   its own branch, terminal, and diff. Ten agents can work in parallel
   without stepping on each other, and they keep working after you close
   your laptop.
3. **The agent runs CI itself on [RWX](https://www.rwx.com).** With
   `rwx run --wait`, an agent can send its uncommitted changes to real CI,
   wait for the result, and get back instructions for pulling the failing
   logs. It can fix its own failures without you pasting logs into the chat.
   RWX also covers what the workspace can't do. [Dagger](https://dagger.io)
   needs container features that Conductor's sandboxes don't provide, so
   Dagger pipelines run inside RWX tasks, and the agent downloads the
   results with `rwx artifacts download`. Heavy work still gets done from a
   lightweight workspace.
4. **[roborev](https://roborev.io) reviews the change in the workspace,
   before it's pushed.** roborev runs locally, with no hosted service. By
   default it reviews every commit in the background, but this repo runs it
   as a blocking step instead (`roborev review --wait`): the agent waits for
   the verdict and fixes what it finds before pushing. Problems are cheapest
   to fix while the agent still has the context, and background findings
   that arrive later are easy to ignore.
5. **[Pullfrog](https://pullfrog.com) reviews it again on the pull request.**
   Pullfrog is an open-source GitHub bot that runs real coding agents inside
   your own GitHub Actions, with your own model keys. Here it reviews every
   pull request, and its approval is a required check. An agent can only
   clear it by fixing and resolving each comment. When nobody else reads
   your code, two reviews at two different moments are the closest you get
   to a teammate.
6. **Agents record what they learn in [cq](https://docs.mozilla.ai/cq).**
   cq is Mozilla.ai's open standard for shared agent learning. Before an
   agent acts, it checks the store for known pitfalls. When it works out
   something non-obvious, like an undocumented behavior or a workaround that
   took several attempts, it proposes that lesson so the next agent doesn't
   have to rediscover it.
7. **Agents share one task list through
   [Beads](https://github.com/gastownhall/beads) and
   [DoltHub](https://www.dolthub.com).** _(Work in progress.)_ Beads is an
   issue tracker built for agents. It stores work as a dependency graph, so
   an agent can ask what's ready to pick up and claim it. Its database is
   [Dolt](https://www.dolthub.com), which works like Git for data, so pushing
   and pulling through DoltHub gives agents in separate workspaces the same
   view of what's done, what's claimed, and what's blocked.
8. **Every agent session is kept with
   [Paper Compute](https://papercompute.com).** _(Work in progress.)_
   `paperctl` routes Claude Code, Codex, or Pi through a small local proxy
   and captures the whole session: prompts, tool calls, token use, and cost.
   Work that used to vanish when the terminal closed becomes history you can
   search by meaning ("why did the deploy fail?"), and the sessions worth
   repeating can become reusable skills.

Big test suites get one more piece. [GTM SDK](https://gtmsdk.com) has a large
one, so it builds and tests with [Bazel](https://bazel.build), which caches
results and reruns only what a change actually affects. Agents get fast
feedback instead of waiting on the whole suite every time.

## The ideas behind it

### Lightweight on purpose

There are no servers to run and no platform to maintain here: just scripts,
prompts, and notes you can read in an afternoon. Every decision assumes one
human and many agents, so things that are easy to understand at a glance win
over things that would scale to a hundred engineers. If understanding a piece
of it would take a dashboard, that piece is too big.

### Every workspace starts the same way

An agent is only as reliable as the machine it runs on. One startup script
sets up every new workspace, both for this repo and for any other project that
uses it. Tools are pinned to exact versions and verified before they're used,
so what worked yesterday still works today. When something is off, there's
one place to look and one place to fix it. Fixes always land here and never
in the individual projects. As soon as a setup fix exists in two places, the
two copies start to drift apart.

### A workspace that looks ready but isn't is worse than one that fails

If a tool you asked for didn't install, setup says so loudly. Otherwise an
agent can lose an hour to a missing command before anyone notices.

### Agents get the same instructions everywhere

The prompts that tell agents how to open a pull request, fix a failing build,
or resolve a merge conflict are written once, here. A script copies them into
each project. When people copy instructions by hand, the copies drift, and
one project quietly keeps last month's advice. An automated check catches a
stale copy before an agent follows it.

### Heavy pieces are opt-in

Not every project needs the Python tooling, the issue syncing, or the private
package catalog. Those pieces exist, but they stay off until a project asks
for them. Adding the setup to a project that doesn't need them should cost
nothing.

### Secrets stay out of the repo

Tokens are read from the environment or a secrets manager at the moment
they're needed. They are never committed to the repo, and wherever possible
they never touch the disk. When you're the only person keeping watch, the
safest secret is one that has nowhere to leak from.

### Prove it before you depend on it

This repo started with one question: could prebuilt [Flox](https://flox.dev)
packages fix the source builds that kept failing in cloud workspaces? Instead
of guessing, we ran the experiment on the real machines and wrote down what
happened, dead ends included. That habit stuck. When this repo says something
works, there's a record of it working in [`findings/`](findings/README.md).
The traps we've already found are written down, so the next person or agent
doesn't fall into them again.

## The supporting cast

These tools aren't steps in the flow, but they keep it running smoothly:

- **[Trunk](https://docs.trunk.io/code-quality/overview)** runs every linter
  and formatter in the repo through one command, `trunk check`, with each
  tool pinned to a fixed version. It flags only issues a change introduces,
  never the backlog, so agents aren't sent off cleaning up old code.
- **[Entire](https://docs.entire.io)** turns every agent commit into a
  checkpoint: the code change together with the prompt, reasoning, and tool
  calls behind it, with secrets redacted before anything leaves the machine.
  Paper keeps whole sessions, and Entire ties the reasoning to the commit, so
  `git blame` can lead back to why.
- **[Flox](https://flox.dev)** resolves one manifest into one lock file, so
  your laptop, CI, and every agent's sandbox run exactly the same software,
  built from prebuilt packages instead of compiled on a fragile machine.
- **uv, pytest, and Reflex** are the Python essentials, for projects that want
  them.

## Where to go next

This page covers the why. The how lives in [`skills/`](skills/): short,
task-focused guides that agents load when they need them and that people can
read too.

| If you want to… | Read |
| --- | --- |
| Set up a workspace, or fix one that came up missing tools | [`conductor-startup-script`](skills/conductor-startup-script/SKILL.md) |
| Debug a startup script that won't build in Conductor | [`conductor-cloud-startup-script-debugging`](skills/conductor-cloud-startup-script-debugging/SKILL.md) |
| Test the startup script locally | [`run-startup-script-tests`](skills/run-startup-script-tests/SKILL.md) |
| Share prompts with another project | [`conductor-prompts`](skills/conductor-prompts/SKILL.md) |
| Pull issues from DoltHub or Linear | [`beads-sync`](skills/beads-sync/SKILL.md) |
| Record or look up what agents learned | [`cq`](skills/cq/SKILL.md) |
| Configure Pullfrog reviews | [`pullfrog-fireworks-setup`](skills/pullfrog-fireworks-setup/SKILL.md) |
| Log in to Entire from a workspace | [`entire-device-login`](skills/entire-device-login/SKILL.md) |
| Re-run the Flox experiments | [`flox-sandbox-harness`](skills/flox-sandbox-harness/SKILL.md) |
| Publish or consume private Flox packages | [`floxhub-auth`](skills/floxhub-auth/SKILL.md) |
| Validate a change on RWX CI before opening a PR | [`rwx`](skills/rwx/SKILL.md) |
| Migrate a GitHub Actions workflow to RWX | [`migrate-from-gha`](skills/migrate-from-gha/SKILL.md) |
| Review an RWX config migrated from GitHub Actions | [`review-gha-migration`](skills/review-gha-migration/SKILL.md) |

The experiment results are in [`findings/`](findings/README.md), and
[issue #16](https://github.com/elviskahoro/flox-conductor-sandbox/issues/16)
has the Flox verdict.
