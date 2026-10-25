---
name: pullfrog-fireworks-setup
description: Use when configuring Pullfrog to run on Fireworks AI via its "Custom (OAI)" / OpenAI-compatible provider, choosing a Fireworks model and its context/max-output limits, or debugging a Pullfrog run that fails on the OPENAI_COMPATIBLE_* settings.
---

# Pullfrog + Fireworks (Custom OAI endpoint)

Pullfrog's **Configure Custom (OAI)** dialog takes five values. Saving all five in the Pullfrog dashboard means `pullfrog.yml` needs no edits: they are injected at run time, stored per organization, and overridable per repo from the repo's Secrets card. Only the key is sensitive.

Docs: https://docs.pullfrog.com/openai-compatible

## The five values

| Variable | Value |
|---|---|
| `OPENAI_COMPATIBLE_BASE_URL` | `https://api.fireworks.ai/inference/v1` (base only; do **not** append `/chat/completions`) |
| `OPENAI_COMPATIBLE_API_KEY` | Fireworks key from https://fireworks.ai/account/api-keys |
| `OPENAI_COMPATIBLE_MODEL` | full id, e.g. `accounts/fireworks/models/ember-1` |
| `OPENAI_COMPATIBLE_CONTEXT` | model context window (see table) |
| `OPENAI_COMPATIBLE_MAX_OUTPUT` | model max output tokens (see table) |

Both limits are required and must be the model's real limits.

## Recommended model

Default to **Ember-1** (Fireworks-tuned Kimi K3, ~40% shorter reasoning, good for agentic coding):

```
OPENAI_COMPATIBLE_BASE_URL=https://api.fireworks.ai/inference/v1
OPENAI_COMPATIBLE_MODEL=accounts/fireworks/models/ember-1
OPENAI_COMPATIBLE_CONTEXT=1048576
OPENAI_COMPATIBLE_MAX_OUTPUT=262000
```

## Model limits (tool-calling chat models)

Model ids go in verbatim. Output limits marked ✱ are estimates (Fireworks does not publish them); lower them if requests are rejected. Snapshot from 2026-10-18; re-check `GET https://api.fireworks.ai/inference/v1/models` for drift.

| Model id | CONTEXT | MAX_OUTPUT | Images |
|---|---|---|---|
| `accounts/fireworks/models/ember-1` | 1048576 | 262000 ✱ | ✓ |
| `accounts/fireworks/models/kimi-k3` | 1048576 | 262000 | ✓ |
| `accounts/fireworks/routers/kimi-k3-fast` | 1048576 | 262000 ✱ | ✓ |
| `accounts/fireworks/models/glm-5p3` | 1048576 | 131072 ✱ | ✗ |
| `accounts/fireworks/routers/glm-5p3-fast` | 1048576 | 131072 ✱ | ✗ |
| `accounts/fireworks/models/glm-5p3-flash` | 1048576 | 131072 ✱ | ✓ |
| `accounts/fireworks/models/deepseek-v4p1-flash` | 1048576 | 384000 | ✓ |
| `accounts/fireworks/models/qwen3p8-max` | 262144 ✱ | 65536 ✱ | ✓ |
| `accounts/fireworks/models/qwen3p8-2p4t-a95b` | 262144 | 65536 ✱ | ✗ |
| `accounts/fireworks/models/minimax-m3` | 512000 | 512000 | ✓ |
| `accounts/fireworks/models/nemotron-3-ultra-nvfp4` | 262144 | 32768 ✱ | ✗ |
| `accounts/fireworks/models/gpt-oss-120b` | 131072 | 32768 | ✗ |
| `accounts/fireworks/models/inkling` | 1048576 | 131072 ✱ | ✓ |

Avoid `auto` / `firerouter/auto` (limits depend on the routed model, so CONTEXT/MAX_OUTPUT can't be set truthfully) and `muse-spark-open` (chat not advertised). Embedding/reranker models use other endpoints and don't work here.

## Steps

1. Pullfrog dashboard → provider settings → **Custom (OAI)** → Configure.
2. Enter the five values above. A saved value shows as `************` with a trash icon; to replace one, delete it and re-enter.
3. Keep the `OPENAI_COMPATIBLE_*` lines in `.github/workflows/pullfrog.yml` commented out. Dashboard values are injected at run time; only uncomment them to configure per-workflow instead (then add `OPENAI_COMPATIBLE_API_KEY` as a GitHub Actions secret).
4. For a per-repo override (e.g. a different model), use that repo's Secrets card.
5. Never paste the API key into the repo, PRs, or notes.

## Verify the endpoint before blaming Pullfrog

```bash
curl https://api.fireworks.ai/inference/v1/chat/completions \
  -H "Authorization: Bearer $FIREWORKS_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"accounts/fireworks/models/ember-1","messages":[{"role":"user","content":"hello"}]}'
```

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| 404 on every call | BASE_URL includes `/chat/completions`, or lacks `/inference/v1` |
| 401/403 | key wrong/expired; re-delete and re-enter the stored key |
| "model not found" | short id used; use the full `accounts/fireworks/...` id |
| 400 on max tokens | MAX_OUTPUT exceeds the model's real limit (✱ estimates); lower it |
| Run ignores Fireworks | another provider key secret (e.g. `ANTHROPIC_API_KEY`) is also set; remove it or confirm which one Pullfrog picks |
