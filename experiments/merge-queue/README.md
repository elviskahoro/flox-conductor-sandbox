# Merge queue experiment

Goal: see how GitHub's merge queue and `gh pr merge` behave.

## Setup (repo admin; merge queue may require an org-owned repo)
Create the `mq-experiment-base` branch, then add the ruleset (run with a token that can write rulesets):

    gh api -X POST repos/OWNER/REPO/rulesets --input experiments/merge-queue/ruleset.json

Or in the UI: Settings > Rules > New branch ruleset > target `mq-experiment-base` > "Require merge queue".

## Run
    experiments/merge-queue/run.sh 3   # opens 3 PRs against mq-experiment-base and queues each

## Observe
    gh api graphql -f query='{repository(owner:"OWNER",name:"REPO"){mergeQueue(branch:"mq-experiment-base"){entries(first:10){nodes{position state pullRequest{number}}}}}}'
