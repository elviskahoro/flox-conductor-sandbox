#!/usr/bin/env bash
# Leftover-conflict check for the resolve-merge-conflicts prompt.
# Any output besides "clean" means a conflict is still open.
set -u
rc=0
git diff --check || rc=1
# shellcheck disable=SC2046
grep -rnE '^(<<<<<<<|=======|>>>>>>>|\|\|\|\|\|\|\|)( |$)' $(git diff --name-only --cached) 2>/dev/null && rc=1
unmerged="$(git diff --name-only --diff-filter=U)"
[ -z "$unmerged" ] || { printf 'unmerged:\n%s\n' "$unmerged"; rc=1; }
[ "$rc" -ne 0 ] || echo clean
exit "$rc"
