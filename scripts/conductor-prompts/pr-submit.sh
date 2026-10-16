#!/usr/bin/env bash
# Create or update the PR for the create-pr prompt.
# Usage: pr-submit.sh <base> <push_head> <existing_pr_number|none> <title> <body-file> [issue-number...]
# Each trailing issue number must have a Closes/Fixes/Resolves keyword in the body.
set -u
[ "$#" -ge 5 ] || { echo "usage: pr-submit.sh <base> <push_head> <existing_pr_number|none> <title> <body-file> [issue-number...]" >&2; exit 2; }
base="$1"; push_head="$2"; existing_pr_number="$3"; title="$4"; body_file="$5"; shift 5
[ -r "$body_file" ] || { echo "body file $body_file is not readable" >&2; exit 1; }
PR_BODY="$(cat "$body_file")"
for ISSUE_NUMBER in "$@"; do
  grep -qiE "(closes|fixes|resolves) #${ISSUE_NUMBER}([^[:alnum:]_]|$)" <<< "$PR_BODY" || {
    echo "missing closing keyword for #${ISSUE_NUMBER}" >&2
    exit 1
  }
done
case "$base" in
  ''|*'<'*|*'>'*) echo "base still contains a placeholder; resolve it from pr-preflight" >&2; exit 1 ;;
esac
case "$existing_pr_number" in
  none) ;;
  ''|*[!0-9]*) echo "existing_pr_number must be a numeric PR number or none" >&2; exit 1 ;;
esac
case "$push_head" in
  *:*) ;;
  *) echo "push_head must be a confirmed <owner>:<branch> value from preflight" >&2; exit 1 ;;
esac
case "$push_head" in
  *'<'*|*'>'*) echo "push_head still contains a placeholder; resolve it from preflight" >&2; exit 1 ;;
esac
if [ "$existing_pr_number" = none ]; then
  gh pr create --base "$base" --head "$push_head" --title "$title" --body "$PR_BODY"
else
  gh pr edit "$existing_pr_number" --title "$title" --body "$PR_BODY"
fi
