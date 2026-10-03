#!/usr/bin/env bash
# Opens N PRs against mq-experiment-base and enqueues each with `gh pr merge`.
set -euo pipefail
BASE=mq-experiment-base
N=${1:-3}
git fetch origin main
git push origin origin/main:refs/heads/$BASE 2>/dev/null || true
git fetch origin $BASE
for i in $(seq 1 "$N"); do
  b=mq-exp-$i-$(date +%s)
  git checkout -q -b "$b" "origin/$BASE"
  echo "entry $i $(date -u +%FT%TZ)" > "experiments/merge-queue/entry-$b.txt"
  git add experiments/merge-queue && git commit -qm "mq experiment entry $i"
  git push -q -u origin "$b"
  url=$(gh pr create --base "$BASE" --head "$b" --title "mq experiment $i" --body "merge queue experiment")
  gh pr merge "$url" --squash --auto
done
