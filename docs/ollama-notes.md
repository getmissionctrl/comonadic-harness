# Ollama notes

Fill this in from observation, not from the docs. Record the version.

    ollama --version
    ollama list

## Model tag

    (record the exact tag here; keep it in config, never as a literal)

## num_ctx

Default observed:
Set to (low value) for compaction experiments:

## Overflow behaviour

The question: when the prompt exceeds `num_ctx`, does Ollama

  (a) truncate silently, in which case `Overflow` must be inferred by
      comparing `prompt_eval_count` against `num_ctx`, or
  (b) return a clean error, in which case `decode` handles it directly?

Observed:

## Tool calling

Does the model honour the `tools` array? Rate of:
  - hallucinated tool names (not in the affordance list)
  - malformed argument JSON
  - calls emitted with no tools supplied

These numbers drive task T6 (defect D3).

## Usage fields

`prompt_eval_count` -> Usage.inTok
`eval_count`        -> Usage.outTok

Confirmed:
