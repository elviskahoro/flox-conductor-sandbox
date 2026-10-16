#!/usr/bin/env bash
# Self-test for the conductor prompt helpers: temp git repo + bare "origin"
# reached over a fake ssh transport, and a stub `gh`. No network.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
ok()  { echo "[prompt-helpers-self-test] PASS  $1"; }
bad() { echo "[prompt-helpers-self-test] FAIL  $1" >&2; fail=1; }
check() { # check <name> <expected-rc> <cmd...>; output kept in $out
  local name="$1" want="$2"; shift 2
  out="$("$@" 2>&1)"; local rc=$?
  if [ "$rc" -eq "$want" ]; then ok "$name"; else bad "$name (rc=$rc, want $want): $out"; fi
}
has() { case "$out" in *"$2"*) ok "$1" ;; *) bad "$1: missing '$2' in: $out" ;; esac; }

export GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0
git config --global user.email t@example.com; git config --global user.name t
git config --global init.defaultBranch main
BARE="$tmp/bare.git"; git init -q --bare "$BARE"
cat > "$tmp/ssh" <<SSH
#!/usr/bin/env bash
cmd="\${*: -1}"; exec \${cmd%% *} "$BARE"
SSH
chmod +x "$tmp/ssh"; export GIT_SSH_COMMAND="$tmp/ssh"
mkdir "$tmp/bin"
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") echo 'no pull requests found' >&2; exit 1 ;;
  "pr list") exit 0 ;;
  "repo view") echo main ;;
  "pr create"|"pr edit") echo "gh $*" >> "$GH_LOG" ;;
  "pr checks") exit 0 ;;
esac
GH
chmod +x "$tmp/bin/gh"; export PATH="$tmp/bin:$PATH" GH_LOG="$tmp/gh.log"

repo="$tmp/work"; git init -q "$repo"; cd "$repo" || exit 1
git remote add origin git@example.com:acme/widgets.git
echo a > f; git add f; git commit -qm base; git push -q origin main
git checkout -qb feature; echo b >> f; git commit -qam change

check "preflight: unpublished branch resolves origin" 0 bash "$here/pr-preflight.sh"
has "preflight: push head" "push_head=acme:feature"
has "preflight: unpublished" "published=no"
git checkout -q main
check "preflight: refuses base branch" 1 bash "$here/pr-preflight.sh"
git checkout -q feature

check "push: usage error" 2 bash "$here/push.sh" main
check "push: rejects placeholder" 1 bash "$here/push.sh" main "<remote>" refs/heads/feature
check "push: refuses base" 1 bash "$here/push.sh" main origin refs/heads/main
check "push: pushes with upstream" 0 bash "$here/push.sh" main origin refs/heads/feature
if [ -n "$(git ls-remote --heads origin feature)" ]; then ok "push: remote has branch"; else bad "push: remote missing branch"; fi
check "preflight: published branch" 0 bash "$here/pr-preflight.sh"
has "preflight: published" "published=yes"

printf '## Why\nFixes #7\n' > "$tmp/body"
check "submit: missing closing keyword" 1 bash "$here/pr-submit.sh" main acme:feature none T "$tmp/body" 8
check "submit: creates PR" 0 bash "$here/pr-submit.sh" main acme:feature none T "$tmp/body" 7
check "submit: edits PR" 0 bash "$here/pr-submit.sh" main acme:feature 12 T "$tmp/body"
check "submit: bad PR number" 1 bash "$here/pr-submit.sh" main acme:feature x T "$tmp/body"
check "submit: bad push_head" 1 bash "$here/pr-submit.sh" main feature none T "$tmp/body"
if grep -q "gh pr create --base main --head acme:feature" "$GH_LOG" && grep -q "gh pr edit 12" "$GH_LOG"; then ok "submit: gh invoked"; else bad "submit: gh log"; fi

check "pr-context: never blocks" 0 bash "$here/pr-context.sh"
has "pr-context: base" "Base for context: main"
check "conflict-context runs" 0 bash "$here/conflict-context.sh"
check "conflict-check: clean tree" 0 bash "$here/conflict-check.sh"
printf '<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> o\n' > g; git add g
check "conflict-check: detects markers" 1 bash "$here/conflict-check.sh"

prompt_source="$here/../../prompts/conductor/create-pr.md"
prompt_settings="$here/../../.conductor/settings.toml"
toml_delimiter="'''"
awk -v start="create_pr = $toml_delimiter" -v end="$toml_delimiter" \
  '$0 == start { in_prompt = 1; next } in_prompt && $0 == end { exit } in_prompt { print }' \
  "$prompt_settings" > "$tmp/installed-create-pr.md"
if cmp -s "$prompt_source" "$tmp/installed-create-pr.md"; then
  ok "create-pr: installed TOML matches the Markdown source"
else
  bad "create-pr: installed TOML differs from the Markdown source"
fi
for prompt in "$prompt_source" "$prompt_settings"; do
  if grep -Fq 'directly asking in unquoted chat to create, open, or publish a PR authorizes publication without separate approval of draft text.' "$prompt"; then
    ok "create-pr: direct publish request skips draft approval in $prompt"
  else
    bad "create-pr: direct publish request skips draft approval in $prompt"
  fi
  if grep -Fq '### Step 8: Show a preview when requested' "$prompt" &&
    grep -Fq 'run only the read-only parts of Steps 1–2, draft with Steps 6–7, show Step 8, and stop.' "$prompt" &&
    grep -Fq 'Do not commit, squash, run publication review, update the base, push, or create/update the PR on a preview-only request.' "$prompt"; then
    ok "create-pr: preview-only requests stop before publication in $prompt"
  else
    bad "create-pr: preview-only requests stop before publication in $prompt"
  fi
  for stale in \
    'approved Step 8 preview' \
    'user-confirmation gate' \
    'preview remains accurate' \
    'Proceed with this action?' \
    'Single publication approval gate' \
    'Show draft, wait for confirmation' \
    'draft approval is still the only user-approval gate'; do
    if grep -Fq "$stale" "$prompt"; then
      bad "create-pr: stale approval wording '$stale' remains in $prompt"
    fi
  done
done

[ "$fail" -eq 0 ] && echo "[prompt-helpers-self-test] all behaviors verified" || exit 1
