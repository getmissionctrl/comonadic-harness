# comonadic-harness

An agentic harness built as a polynomial coalgebra, denoted by a cofree
comonad, with a stated correctness condition for context compaction.

The point of the construction: **execution consumes the shape of the tree,
analysis consumes its annotation.** That split lets you attach a
forward-looking assessment to every reachable state with one call to `extend`,
and it gives compaction a law it can be tested against.

Nothing here is production code. It is a sketch that compiles, runs, and has
been checked against two real harnesses.

## Read in this order

| file | what it is |
|---|---|
| `BRIEF.md` | the design. Start here. Numbered sections; everything else refers into it |
| `TASKS.md` | ordered work with acceptance criteria. T1 is the cabal file |
| `CLAUDE.md` | invariants and evidence discipline for the working session |
| `REFERENCES.md` | prior art, annotated by why it matters here |

## What is in the box

- `reference/Harness.hs` — the original sketch, base-only, hand-rolled
  `Cofree`. Contains `outerLoop` and `respectsBehaviour`.
- `reference/Run.hs` — instrumented demo of that sketch.
- `reference/Oracle.hs` — the amended version with the provider seam, tool
  specs in the request, `Either Refusal Response`, token budgets, and
  overflow-triggered compaction through the ordinary `Render` path. **This is
  the one to port.**
- `runs/run-output.txt`, `runs/oracle-output.txt` — recorded traces. T3's
  acceptance criterion is reproducing the second one.

All three compile clean under GHC 9.x with `base` only and no flags beyond
`-XDeriveFunctor`:

```
ghc -Wall -O0 -main-is Oracle.main reference/Oracle.hs reference/Harness.hs -o oracle && ./oracle
```

## Environment

Ollama serving a local Qwen 3 model. `BRIEF.md` §12 has the specifics, the
gotchas, and the reason a small local model is an asset rather than a
compromise here: it fails in ways that make the harness's weak points
impossible to defer.

Set `options.num_ctx` low. That is how you provoke the compaction path cheaply.
