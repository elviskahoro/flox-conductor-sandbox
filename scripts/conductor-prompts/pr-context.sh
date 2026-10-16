#!/usr/bin/env bash
# Non-blocking PR and branch context for the fix-errors prompt.
git fetch origin || echo "warning: could not refresh origin; continue with local and user-provided errors"
pr_state=unknown
base=""
pr_url=none
pr_number=none
pr_head_sha=none
error_file="$(mktemp 2>/dev/null || true)"
if [ -z "$error_file" ]; then
  echo "warning: could not create a temporary error file; skipping PR metadata"
else
  trap 'rm -f "$error_file"' EXIT
  if pr_info="$(gh pr view --json state,baseRefName,url,number,headRefOid --jq '[.state,.baseRefName,.url,(.number|tostring),.headRefOid] | map(if . == null then "" else tostring end) | join("\u001f")' 2>"$error_file")"; then
    IFS=$'\x1f' read -r pr_state base pr_url pr_number pr_head_sha <<< "$pr_info"
    if [ "$pr_state" != "OPEN" ]; then echo "PR is $pr_state; use local or user-provided errors, not active PR checks"; fi
  else
    pr_error="$(cat "$error_file")"
    echo "warning: PR metadata unavailable: $pr_error"
  fi
fi
if [ -z "$base" ] && command -v gh >/dev/null 2>&1; then
  base="$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null || true)"
fi
if [ -z "$base" ]; then
  base="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
fi
if [ -z "$base" ]; then
  for candidate in main master; do
    if git rev-parse --verify "refs/remotes/origin/$candidate" >/dev/null 2>&1 || git rev-parse --verify "refs/heads/$candidate" >/dev/null 2>&1; then base="$candidate"; break; fi
  done
fi
if [ -n "$base" ]; then
  printf 'Base for context: %s\n' "$base"
  if git rev-parse --verify "refs/remotes/origin/$base" >/dev/null 2>&1; then
    git log "origin/$base"..HEAD --oneline
  elif git rev-parse --verify "refs/heads/$base" >/dev/null 2>&1; then
    git log "$base"..HEAD --oneline
  else
    echo "warning: base $base is not available locally; skipping branch log"
  fi
else
  echo "warning: no base could be determined; continuing without branch context"
fi
printf 'PR context: state=%s url=%s number=%s head_sha=%s\n' "$pr_state" "$pr_url" "$pr_number" "$pr_head_sha"
if [ "$pr_state" = "OPEN" ]; then
  gh pr checks
  checks_status=$?
  if [ "$checks_status" -ne 0 ] && [ "$checks_status" -ne 1 ] && [ "$checks_status" -ne 8 ]; then
    echo "gh pr checks could not complete (exit $checks_status); inspect the output above"
  fi
else
  echo "No open PR; skip active PR checks."
fi
