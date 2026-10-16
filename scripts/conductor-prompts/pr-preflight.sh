#!/usr/bin/env bash
# PR preflight for the create-pr prompt: resolves branch publication, base,
# open-PR head, and the push target. Prints a labeled "PR preflight:" line.
# Exits nonzero (with the reason on stderr) on any stop condition.
git fetch origin || { echo "could not refresh origin refs; stop before classifying or updating this branch" >&2; exit 1; }
branch="$(git branch --show-current)"
[ -n "$branch" ] || { echo "detached HEAD; cannot classify this branch" >&2; exit 1; }
upstream_remote="$(git config --get "branch.$branch.remote" || true)"
upstream_ref="$(git config --get "branch.$branch.merge" || true)"
published=no
matched_remotes=""
match_count=0
remote_count=0
lookup_failed=no
pr_url=""
pr_remote=none
pr_candidates=""
push_remote=""
push_ref=""
push_confirmation=no
export GIT_TERMINAL_PROMPT=0
for remote in $(git remote); do
  remote_count=$((remote_count + 1))
  matches="$(git ls-remote --heads "$remote" "refs/heads/$branch")" || { echo "warning: could not inspect candidate remote $remote" >&2; lookup_failed=yes; continue; }
  if [ -n "$matches" ]; then
    matched_remotes="${matched_remotes}${matched_remotes:+,}$remote"
    match_count=$((match_count + 1))
    published=yes
  fi
done
error_file="$(mktemp)" || { echo "could not create a temporary error file" >&2; exit 1; }
trap 'rm -f "$error_file"' EXIT
if pr_info="$(gh pr view --json state,baseRefName,number,url,headRefName,headRepositoryOwner,headRepository --jq '[.state,.baseRefName,(.number|tostring),.url,.headRefName,.headRepositoryOwner.login,.headRepository.name] | map(if . == null then "" else tostring end) | join("\u001f")' 2>"$error_file")"; then
  IFS=$'\x1f' read -r pr_state base pr_number pr_url pr_head_branch pr_head_owner pr_head_repo <<< "$pr_info"
  if [ "$pr_state" != "OPEN" ]; then echo "PR is $pr_state; stop and offer a new branch name or ask for explicit confirmation to open a new PR from this head" >&2; exit 1; fi
  pr_head="$pr_head_owner/$pr_head_repo"
  published=yes
else
  pr_error="$(cat "$error_file")"
  : > "$error_file"
  if pr_candidates="$(gh pr list --head "$branch" --state all --json number,url,state,headRefName,headRepositoryOwner,headRepository --jq '.[] | [.number,.url,.state,.headRefName,.headRepositoryOwner.login,.headRepository.name] | map(if . == null then "" else tostring end) | join("\u001f")' 2>"$error_file")"; then
    base="$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)" || { echo "could not resolve the repository's default base" >&2; exit 1; }
  else
    echo "could not determine whether a PR already exists; gh pr view failed: $pr_error; gh pr list failed: $(cat "$error_file")" >&2
    exit 1
  fi
  pr_state=none
  pr_number=none
  pr_url=none
  pr_head=none
fi
[ -n "$base" ] || { echo "could not resolve a base branch" >&2; exit 1; }
[ "$branch" != "$base" ] || { echo "current branch is the base branch; stop before changing history or pushing" >&2; exit 1; }
git rev-parse --verify "refs/remotes/origin/$base" >/dev/null || { echo "origin/$base is unavailable after fetch" >&2; exit 1; }
if [ -n "$upstream_ref" ] && [ "$upstream_ref" != "refs/heads/$base" ] && [ -n "$upstream_remote" ] && [ "$upstream_remote" != "." ]; then
  if [ "$pr_state" != "OPEN" ]; then
    upstream_matches="$(git ls-remote --heads "$upstream_remote" "$upstream_ref")" || { echo "could not inspect upstream $upstream_remote:$upstream_ref" >&2; exit 1; }
    if [ -n "$upstream_matches" ]; then
      published=yes
      push_remote="$upstream_remote"
      push_ref="$upstream_ref"
      [ "$upstream_ref" = "refs/heads/$branch" ] || push_confirmation=yes
    else
      echo "warning: configured upstream $upstream_remote:$upstream_ref no longer exists; treating this branch as unpublished"
      upstream_remote=""
      upstream_ref=""
    fi
  else
    published=yes
  fi
fi
if [ "$pr_state" = OPEN ] && [ -z "$push_remote" ]; then
  [ -n "$pr_head_branch" ] && [ -n "$pr_head_owner" ] && [ -n "$pr_head_repo" ] || { echo "open PR has incomplete head details; surface the push-target ambiguity" >&2; exit 1; }
  pr_remote_count=0
  pr_seen_remote_urls=()
  pr_head_lc="$(printf '%s' "$pr_head" | tr '[:upper:]' '[:lower:]')"
  for remote in $(git remote); do
    remote_url="$(git ls-remote --get-url "$remote")" || { echo "could not inspect URL for remote $remote" >&2; exit 1; }
    remote_url_key="${remote_url%/}"
    remote_url_key="${remote_url_key%.git}"
    remote_url_lc="$(printf '%s' "$remote_url_key" | tr '[:upper:]' '[:lower:]')"
    remote_seen=no
    for seen_remote_url in "${pr_seen_remote_urls[@]}"; do
      [ "$seen_remote_url" = "$remote_url_lc" ] && remote_seen=yes
    done
    [ "$remote_seen" = no ] || continue
    pr_seen_remote_urls+=("$remote_url_lc")
    case "$remote_url" in
      *://*) remote_repo_path="${remote_url#*://}"; remote_repo_path="${remote_repo_path#*/}" ;;
      *@*:* ) remote_repo_path="${remote_url#*:}" ;;
      *) continue ;;
    esac
    remote_repo_path="${remote_repo_path%/}"
    remote_repo_path="${remote_repo_path%.git}"
    case "$remote_repo_path" in */*) remote_owner="${remote_repo_path%%/*}"; remote_repo_name="${remote_repo_path#*/}" ;; *) continue ;; esac
    case "$remote_repo_name" in */*|"") continue ;; esac
    remote_head_lc="$(printf '%s/%s' "$remote_owner" "$remote_repo_name" | tr '[:upper:]' '[:lower:]')"
    if [ "$remote_head_lc" = "$pr_head_lc" ]; then
      pr_remote="$remote"
      pr_remote_count=$((pr_remote_count + 1))
    fi
  done
  [ "$pr_remote_count" -eq 1 ] || { echo "could not uniquely map PR head $pr_head to a configured remote; ask the user which remote to push and confirm the <owner>:<branch> PR head" >&2; exit 1; }
  push_remote="$pr_remote"
  push_ref="refs/heads/$pr_head_branch"
  pr_head_matches="$(git ls-remote --heads "$push_remote" "$push_ref")" || { echo "could not inspect open PR head $push_remote:$push_ref" >&2; exit 1; }
  [ -n "$pr_head_matches" ] || { echo "open PR head $push_remote:$push_ref is missing; surface the push-target ambiguity" >&2; exit 1; }
  [ "$pr_head_branch" = "$branch" ] || push_confirmation=yes
fi
if [ "$lookup_failed" = yes ]; then
  if [ "$pr_state" != "OPEN" ] && [ "$match_count" -eq 0 ] && [ -z "$push_remote" ]; then
    echo "could not classify the branch because at least one configured remote was unreachable; surface the ambiguity before changing history or pushing" >&2
    exit 1
  fi
  echo "warning: one or more unrelated remote lookups failed; verify the exact push target before proceeding"
  [ "$pr_state" = OPEN ] || [ -n "$push_remote" ] || push_confirmation=yes
fi
if [ "$published" = yes ]; then
  if [ -z "$push_remote" ]; then
    [ "$match_count" -le 1 ] || { echo "multiple push remotes match ($matched_remotes); stop and ask which one to use" >&2; exit 1; }
    if [ "$match_count" -eq 1 ]; then
      push_remote="$matched_remotes"
      push_ref="refs/heads/$branch"
      push_confirmation=yes
    fi
  fi
elif [ -z "$push_remote" ]; then
  [ "$remote_count" -le 1 ] || { echo "new branch has multiple configured remotes and no existing push target; ask which remote to use" >&2; exit 1; }
  git remote get-url origin >/dev/null 2>&1 || { echo "new branch has no origin remote; surface the push target" >&2; exit 1; }
  push_remote=origin
  push_ref="refs/heads/$branch"
fi
[ -n "$push_remote" ] && [ -n "$push_ref" ] || { echo "push target is ambiguous; surface it before continuing" >&2; exit 1; }
[ "$push_ref" != "refs/heads/$base" ] || { echo "push target is the base branch; stop before pushing" >&2; exit 1; }
push_remote_url="$(git ls-remote --get-url "$push_remote")" || { echo "could not inspect push remote URL" >&2; exit 1; }
case "$push_remote_url" in
  *://*) push_repo="${push_remote_url#*://}"; push_repo="${push_repo#*/}" ;;
  *@*:* ) push_repo="${push_remote_url#*:}" ;;
  *) echo "could not map push remote to a GitHub owner/repository; ask the user to confirm the push remote and <owner>:<branch> PR head" >&2; exit 1 ;;
esac
push_repo="${push_repo%.git}"
case "$push_repo" in */*) push_owner="${push_repo%%/*}"; push_repo_name="${push_repo#*/}" ;; *) echo "could not map push remote to a GitHub owner/repository; ask the user to confirm the push remote and <owner>:<branch> PR head" >&2; exit 1 ;; esac
case "$push_owner:$push_repo_name" in :*|*:|*/*) echo "push remote URL has an unsupported path; ask the user to confirm the push remote and <owner>:<branch> PR head" >&2; exit 1 ;; esac
if [ "$pr_state" = none ] && [ -n "$pr_candidates" ]; then
  while IFS=$'\x1f' read -r candidate_number candidate_url candidate_state candidate_branch candidate_owner candidate_repo; do
    if [ "$candidate_branch" = "$branch" ] && [ "$(printf '%s' "$candidate_owner" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$push_owner" | tr '[:upper:]' '[:lower:]')" ] && [ "$(printf '%s' "$candidate_repo" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$push_repo_name" | tr '[:upper:]' '[:lower:]')" ]; then
      echo "PR #$candidate_number ($candidate_url, $candidate_state) matches the resolved push head; inspect it by number. For a closed or merged PR, offer a new branch name or ask for explicit confirmation to open a new PR from this head" >&2
      exit 1
    fi
  done <<< "$pr_candidates"
fi
push_branch="${push_ref#refs/heads/}"
push_head="$push_owner:$push_branch"
printf 'PR preflight: branch=%s published=%s base=%s matching_remotes=%s upstream_remote=%s upstream_ref=%s pr_state=%s pr_number=%s pr_url=%s pr_head=%s pr_remote=%s push_remote=%s push_ref=%s push_head=%s push_confirmation=%s\n' "$branch" "$published" "$base" "${matched_remotes:-none}" "${upstream_remote:-none}" "${upstream_ref:-none}" "$pr_state" "$pr_number" "$pr_url" "$pr_head" "$pr_remote" "$push_remote" "$push_ref" "$push_head" "$push_confirmation"
git remote -v | sed -E 's#(https?://)[^/@]+@#\1[redacted]@#'
git log "origin/$base"..HEAD --oneline
git diff "origin/$base"...HEAD --stat
git log '@{upstream}..HEAD' --oneline 2>/dev/null || true
