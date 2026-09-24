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
      heuristic means, or
  (b) return a clean error, in which case `decode` handles it directly?

**Observed: (a) — silent truncation.** [established]

With `numCtx=64` and a ~50-sentence prompt (~550 chars ≈ 137 tokens):
- `promptEvalCount = 34` (only template overhead + truncated tail fit)
- `doneReason = "stop"` (not "length"!)
- The model answers as if it only saw the truncated fragment

With `numCtx=256` and the same prompt:
- `promptEvalCount = 130` (the full prompt fits within 256 tokens)
- `doneReason = "stop"` (normal completion)

Key findings from original observation:
1. `doneReason = "length"` fires ONLY when `numPredict` is set explicitly to
   a positive value — it is NOT a reliable overflow signal without `numPredict`.
2. There is no API-level error for prompt overflow; Ollama truncates in silence.

### Current overflow heuristic: `overflowByEstimate` [design]

The current implementation (`Provider.Ollama.overflowByEstimate`) compares an
estimated token count of the *actually-sent* content against `ocNumCtx` with a
15% headroom margin for chat-template and tool-schema overhead:

    estTokens    = length(sentText) `div` 4
    budgetTokens = (ocNumCtx * 85) `div` 100
    overflow     = estTokens > budgetTokens

The text measured is `sentText`: the concatenation of `reqMessages` when
present (the native multi-turn path), falling back to `reqPrompt` (the
compaction/summarising path). Both `decodeResp` and `streamingComplete` use the
same shared helper so the two decode paths cannot drift.

The 4-chars/token estimate is [speculative] — it is a rough average for English
prose with ASCII tool names; Unicode-heavy input will be underestimated.  A
native overflow signal or an exact tokeniser would supersede it.

### Why the old `promptEvalCount`-based heuristic was superseded

The previous heuristic compared `promptEvalCount` (tokens *evaluated* on this
request) against `0.6 × (promptChars / 4)`, inferring truncation when the
model had evaluated far fewer tokens than the prompt implied.  That signal
collapses under Ollama's prefix/KV-cache: a long prompt whose prefix is already
in cache evaluates very few *new* tokens, producing a low `promptEvalCount`
regardless of whether truncation occurred.  The old heuristic therefore
false-positived on warm cache hits — a prompt that fit comfortably was reported
as `Overflow` simply because the server had cached its prefix (F3, review1 #8).

The new heuristic reads only the *configured* window (`ocNumCtx`) and the
estimated size of the sent content.  It is independent of `promptEvalCount`
entirely, so cache warmth cannot affect it.  The trade-off is that it fires
before the request is sent (no server round-trip needed) but cannot detect
partial caching or model-specific tokenisation differences. [design]

### Cache-hit vs overflow (PENDING measurement)

The empirical interaction between Ollama's KV-cache and the overflow signal has
NOT yet been measured in this environment — no running Ollama server was
available when this section was written. [unbuilt]

A maintainer should gather the following data and replace the
`TODO(measure)` placeholders below:

**Setup**

    ollama --version
    # TODO(measure): record full version string here

    ollama list
    # TODO(measure): record model tag and digest here

**Cold vs warm cache observation**

Goal: demonstrate that `promptEvalCount` drops dramatically on a warm cache
hit, confirming the false-positive collision the old heuristic suffered.

    # Pull the model if not already present
    ollama pull qwen3:8b

    # Set a small context to make overflow easy to provoke (adjust path as needed)
    cabal run demo -- live --ctx 256 "read the README and summarise it"
    # TODO(measure): record promptEvalCount and doneReason from first (cold) run

    cabal run demo -- live --ctx 256 "read the README and summarise it"
    # TODO(measure): record promptEvalCount and doneReason from second (warm) run

Expected finding: `promptEvalCount` should be substantially lower on the warm
run even though the prompt is identical and fits within `num_ctx=256`.
[speculative]

**Overflow signal verification**

Goal: confirm that `overflowByEstimate` fires from `num_ctx` independently
of `promptEvalCount`.

    # Use a context window too small to hold the prompt
    cabal run demo -- live --ctx 64 "read the README and summarise it"
    # TODO(measure): record promptEvalCount, doneReason, and whether
    #                Overflow was raised by the harness

Confirm that:
- `overflowByEstimate` raises `Overflow` when `length(sentText) / 4 > 64 * 85 / 100`
  (i.e. estimated tokens exceed ~54)
- This fires regardless of what `promptEvalCount` reports
- A warm second call with the same small-context prompt also raises `Overflow`
  (the estimate is deterministic; caching cannot suppress it)

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
- `specSchema` IS now parsed. `Provider.Ollama.schemaOf` translates the terse
  `{k:type,...}` DSL into a typed `FunctionParameters` object (required
  properties, `additionalProperties: false`) via `parseSpec`.  The old
  empty-schema advertisement was the reason a stricter model emitted `{}` for
  arguments; the typed schema fixes that.  The note above about argument keys
  being inferred from context applied only before this change. [established]

## Usage fields

`prompt_eval_count` → `Usage.inTok`
`eval_count`        → `Usage.outTok`

Confirmed: smoke test (a) with "What is 2+2?" → `inTok=164, outTok=12`.
Token counts include the Qwen3 chat template overhead (~140-160 tokens baseline).
