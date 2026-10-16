#!/usr/bin/env bash
# Push for the create-pr prompt. Usage: push.sh <base> <push_remote> <push_ref>
# Values come from the approved pr-preflight output.
set -u
[ "$#" -eq 3 ] || { echo "usage: push.sh <base> <push_remote> <push_ref>" >&2; exit 2; }
base="$1"; push_remote="$2"; push_ref="$3"
upstream_remote="$(git config --get "branch.$(git branch --show-current).remote" || true)"
upstream_ref="$(git config --get "branch.$(git branch --show-current).merge" || true)"
for value in "$base" "$push_remote"; do
  case "$value" in
    ''|*'<'*|*'>'*) echo "base and push_remote must be resolved from the approved preflight" >&2; exit 1 ;;
  esac
done
[ -n "$push_ref" ] || { echo "push_ref must be resolved from the approved preflight" >&2; exit 1; }
[ "$push_ref" != "refs/heads/$base" ] || { echo "push target is the base branch; stop before pushing" >&2; exit 1; }
needs_upstream=no
if [ -z "$upstream_remote" ] || [ "$upstream_remote" = "." ] || [ -z "$upstream_ref" ] || [ "$upstream_ref" = "refs/heads/$base" ]; then
  needs_upstream=yes
else
  upstream_matches="$(git ls-remote --heads "$upstream_remote" "$upstream_ref")" || { echo "could not verify configured upstream; stop before pushing" >&2; exit 1; }
  [ -n "$upstream_matches" ] || needs_upstream=yes
fi
if [ "$needs_upstream" = yes ]; then
  git push -u "$push_remote" "HEAD:$push_ref"
else
  git push "$push_remote" "HEAD:$push_ref"
fi
