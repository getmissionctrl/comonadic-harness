# Ollama notes

Filled from live observation against `<my-ollama>` on 2026-08-26.

    Server version: 0.32.13 (from /api/version; `ollama --version` not run directly)
    Client library: ollama-haskell 0.2.1.0

## Model tag

    qwen3:8b

Used as `defaultOllamaCfg.ocModel`. Always reference via `OllamaCfg.ocModel`
— never as a literal in non-config code.

## num_ctx

Default observed: not explicitly tested; Ollama default is 2048 for qwen3:8b.
Set to (low value) for overflow experiments: 64, 256 (see Provider.Ollama `ocNumCtx`).

## Overflow behaviour

The question: when the prompt exceeds `num_ctx`, does Ollama

  (a) truncate silently, in which case `Overflow` must be inferred by
      comparing `prompt_eval_count` against `num_ctx`, or
  (b) return a clean error, in which case `decode` handles it directly?

**Observed: (a) — silent truncation.**

With `numCtx=64` and a ~50-sentence prompt (~550 chars ≈ 137 tokens):
- `promptEvalCount = 34` (only template overhead + truncated tail fit)
- `doneReason = "stop"` (not "length"!)
- The model answers as if it only saw the truncated fragment

With `numCtx=256` and the same prompt:
- `promptEvalCount = 130` (the full prompt fits within 256 tokens)
- `doneReason = "stop"` (normal completion)

Key findings:
1. `doneReason = "length"` fires ONLY when `numPredict` is set explicitly to
   a positive value — it is NOT a reliable overflow signal without `numPredict`.
2. There is no API-level error for prompt overflow; Ollama truncates in silence.
3. The reliable overflow signal is a character-budget comparison:
   if `promptEvalCount * 4 < 0.6 × length(promptText)` and the prompt
   is non-trivial (> 80 chars), the prompt was truncated.

Implementation in `Provider.Ollama.decodeResp`: uses the character-budget
heuristic. `charsPerTok = 4`, threshold factor `0.6` (conservative, minimises
false positives on short prompts or rich Unicode).

## Tool calling

qwen3:8b **does** honour the `tools` array and emits `tool_calls` correctly.

Observed in smoke test (c):

    Request: "What is the weather in London? Use the get_weather tool."
    Tools:   [ToolSpec "get_weather" "{\"type\":\"object\"}"]
    Response: calls = [Call {tool = "get_weather", args = "{\"location\":\"London\"}"}]
              say   = ""   (no text alongside the call)
              usage = Usage {inTok = 223, outTok = 20}

Notes:
- The model emits a tool call with correct name and plausible arguments.
- The `say` field is empty when a tool call is returned (model chooses one or the other).
- Argument JSON is keyed `"location"` which was not in the empty parameter schema
  (we provide `FunctionParameters "object" Nothing Nothing Nothing`). The model
  infers sensible argument keys from the prompt context — acceptable for this task.
- No hallucinated tool names observed in initial tests.
- `specSchema` is NOT parsed; the permissive empty schema is sufficient for qwen3:8b.

## Usage fields

`prompt_eval_count` → `Usage.inTok`
`eval_count`        → `Usage.outTok`

Confirmed: smoke test (a) with "What is 2+2?" → `inTok=164, outTok=12`.
Token counts include the Qwen3 chat template overhead (~140-160 tokens baseline).
