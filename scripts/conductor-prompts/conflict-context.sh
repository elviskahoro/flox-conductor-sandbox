#!/usr/bin/env bash
# Pre-flight context for the resolve-merge-conflicts prompt.
git status
git branch --show-current
git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null
git log '@{upstream}..HEAD' --oneline 2>/dev/null
gh repo view --json defaultBranchRef --jq .defaultBranchRef.name
gh pr view --json url,state,baseRefName,mergeable,mergeStateStatus 2>/dev/null
git fetch origin
