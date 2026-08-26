# Build handoff — comonadic-harness

Live state of the subagent-driven build of Tasks T1–T7. Read `BRIEF.md` for the
design, `TASKS.md` for T1–T7, and `docs/superpowers/plans/2026-08-26-comonadic-harness.md`
for the 23-task implementation plan this build is executing.

## Where we are

- **Branch:** `build/harness-t1-t7` (do NOT work on `main`).
- **Last commit:** `71387fa` (demo + live run).
- **Done: tasks 1–18 of 23.** T1 (cabal), T2 (nix/direnv, hq confirmed, vf-haskell
  `.envrc`), T3 (the whole port — 8 library modules), T4 (law-test suite), T5
  (Ollama provider + demo, both live-verified on hq).
- **Remaining: tasks 19–23** — see "Next" below.

## Verification snapshot (all currently green)

- Library builds with **zero GHC warnings** (8 modules: `Harness.{Alphabet,State,Coalgebra,Interp,Run,Probe,Compaction,Evolve}`).
- Closed-alphabet guard proven: adding a 4th `HarnessF` constructor makes
  `-Wincomplete-patterns` fail in `Harness.Interp` (the only `case` over `HarnessF`).
- Test suite: **7 examples, 0 failures, 1 pending** (`cabal test spec`).
  - Comonad laws (both), **agreement law `run ≡ probe` (100 QC cases)**, prefix-stability all pass.
  - Affordance law (§16.4/D12) is `pending` — Task 20 flips it to a real assertion.
  - Compaction violation-rate over ~2054 reachable states: halt 0%, **writes ~11%,
    oracle-call-count ~23%, per-turn-sets ~38%** (baseline no-op 0%). The headline research result.
- Demo: `cabal run demo` reproduces `runs/oracle-output.txt` — the `== the run ==`
  section and the `probe` line match byte-for-byte; only the Anthropic header
  (dropped) and the `Sum`/`Any`-wrapped `Risk` line differ (accepted formatting).
- **Live:** `cabal run demo live` runs against `hq:11434` (qwen3:8b) → `Exhausted`.
  Provider smoke test confirmed normal chat, tool-calling, and overflow detection.

## Build & test commands (faster path once direnv is allowed)

After `direnv allow` in this directory, the dev shell is cached in `.direnv/`. Use:

```
direnv exec /home/ben/dev/comonadic-harness cabal build
direnv exec /home/ben/dev/comonadic-harness cabal test spec
direnv exec /home/ben/dev/comonadic-harness cabal run demo
direnv exec /home/ben/dev/comonadic-harness cabal run demo live   # hits hq
```

(Equivalent slow path: `nix develop .#dev --command <cmd>` — re-evaluates the flake each call.)

## Key decisions & context (don't relitigate)

- **`ollama-haskell 0.2.1.0`, client only.** 0.4.x isn't in nixpkgs (needs an
  `mcp-server` override cascade); 0.2.1.0 has `numCtx`, tools, usage, configurable
  `hostUrl`. Tool/affordance/MCP semantics live in the harness, not the library.
- **Overflow is inferred, not signalled.** Ollama 0.32.13 silently truncates at
  `num_ctx` (`doneReason` stays `"stop"`). `Provider.Ollama` uses a char-budget
  heuristic (`promptEvalCount*4 < 0.6×promptChars && chars>80`). Empirically
  validated but fragile — the one `[speculative]` area. See `docs/ollama-notes.md`.
- **Five invariants** (in `CLAUDE.md`) are load-bearing: closed alphabet; execution
  never reads the annotation to pick a successor; `Cofree` is denotation not runtime;
  evolution outside the functor; transient failure never reaches the coalgebra
  (handled by `withLocalRetry` in the provider).
- **`Risk` monoid** derives via base's `Generically` (no `generic-data` dep).
- Default model on hq: **`qwen3:8b`**.

## Next — tasks 19–23 (kickoff brief)

Execution model: **subagent-driven** (fresh subagent per task, then spec + code-quality
review). The plan file has full code/steps for each. In order:

1. **Task 19 — T7/D1: monoidal scan for `governed`.** Add `localRisk` + a `scanr1`
   over the hypo path so `governed` is linear along a run's path (vs `assess`'s
   re-probe-per-node). Promote the pure path walk (`takeWalk`, currently in
   `test/Gen.hs`) into a shared `Harness.Path` module so library code can use it
   (don't import test code into the library). **Hard part:** reconcile the scan
   totals with `assess` (off-by-one on `stepsAhead`; `assess` uses `length evs`).
   Deliverable: `test/PerfSpec.hs` agreement + a before/after timing curve, OR a
   written negative result if the monoid can't reproduce the wanted statistic.

2. **Task 20 — T6/D3/D12: admit/repair unafforded calls.** Add an `admit` pass at
   the top of `step` (in `Harness.Coalgebra`) so only afforded calls `Perform`;
   unafforded/hallucinated calls get a synthetic error `Obs` fed back. Then **flip
   the pending affordance-law test in `test/LawsSpec.hs` to a real assertion**
   (`probe` never emits `Did c` whose tool is unafforded at that node). Add
   `test/HostileSpec.hs`: a hostile oracle (hallucinated tools, malformed args,
   empty responses) → **zero harness crashes** over ≥100 seeds (E4).

3. **Task 21 — `Harness.Tutorial`** (pipes-style, Haddock-only, exposed module).
4. **Task 22 — `Harness.Motivation.lhs`** (literate, exposed module, the "why").
5. **Task 23 — phase-2 stub** (`docs/phase-2-recipe-morphism.md`, no code) + README
   build/run section + final verification (full build+test+haddock; trace diff;
   closed-alphabet guard check).

## Open caveats to keep in mind

- The overflow heuristic (above) is the fragile spot; if it misfires under real
  runs, revisit with a token-vs-`num_ctx` comparison.
- `governed`/`assess` is currently O(depth²) (re-probes per node) until Task 19.
- Live qwen3:8b runs are slow (8B model); keep live demos short.
