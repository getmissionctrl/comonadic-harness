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
- `runs/run-output.txt`, `runs/oracle-output.txt` — recorded traces. The second
  is the one the built `demo` reproduces (see *Built module* below).

All three compile clean under GHC 9.x with `base` only and no flags beyond
`-XDeriveFunctor`:

```
ghc -Wall -O0 -main-is Oracle.main reference/Oracle.hs reference/Harness.hs -o oracle && ./oracle
```

## Built module

The port lives under `src/Harness/`: one closed alphabet (`Harness.Alphabet`),
the coalgebra (`Harness.Coalgebra`), a single interpreter both `run` and `probe`
factor through (`Harness.Interp`), counterfactual analysis (`Harness.Probe`),
compaction with its law (`Harness.Compaction`), and evolution
(`Harness.Evolve`). The dev shell is a nix flake mirroring `vf-haskell`.

```bash
nix develop .#dev            # GHC + cabal + HLS; deps from the pinned nixpkgs
cabal build all              # warning-clean under the strict flag set
cabal test spec              # 11 examples: comonad, agreement, prefix, affordance,
                             #   compaction-rate, monoidal-scan, hostile-oracle
cabal run demo               # reproduces runs/oracle-output.txt (pure scripted oracle)
cabal run demo live          # same harness, live against Ollama on hq:11434,
                             #   printing the full annotated trace (built-in task)
# give it your own task (trailing words); flags tune the run:
cabal run demo live -- --ctx 8192 --budget 10000 read README.md then write notes.md summarising it and commit
cabal run demo live -- --model qwen3:30b refactor the parser
```

In `live` mode the tools are **real**, executed by `Provider.Tools` inside a
sandbox (`runs/agent-sandbox`, its own git repo, seeded with a copy of the
README): `read`/`write` are path-confined (a `..`/absolute escape is refused),
`bash` runs there with a 10s timeout, and `commit` is a git commit in that
sandbox — the project repo is never touched. So the agent genuinely reads the
README, writes a file, and commits; a completed run ends `Done` with the model's
summary (see `runs/live-demo.txt`).

The task is seeded as the opening transcript turn (an empty prompt is what real
Ollama rejects). Flags: `--model M`, `--ctx N` (a small `--ctx` provokes the
compaction path; bump it for longer runs), `--budget N` (tokens; raise it so a
real read→write→commit can finish). Note the `--` after `live` so cabal passes
the flags to the demo rather than interpreting them itself.

Two guided reads:

- **The *how*** — `Harness.Tutorial`, a Haddock walk from the closed alphabet
  through `step`, `unfold`, `run` versus `governed`, `extend`, and the compaction
  law. A pre-rendered HTML snapshot of the whole API is committed under
  **`docs/api/`** (open `docs/api/index.html`); regenerate with
  `cabal haddock lib:comonadic-harness --haddock-hyperlink-source`.
- **The *why*** — `docs/motivation.md`, a standalone essay arguing the comonadic
  design against how coding agents are normally built. It is prose, not a module,
  so it typesets to a proper PDF: run `scripts/motivation-pdf.sh` to (re)generate
  the committed **`docs/motivation.pdf`** (pandoc + tectonic, via nix).

### A note on the demo trace

`runs/oracle-output.txt` is the current `demo` output. At **step 9** the scripted
oracle emits a `commit` at a node where `commit` is not afforded (compaction has
wiped the earlier `write` from view). The coalgebra's admission pass (T6/D3)
*repairs* the unafforded call into a synthetic error observation rather than
performing it — so, unlike a pre-T6 recording, no `PERFORM commit` follows. The
divergence is the D3 behaviour demonstrated live, not a regression.

## Environment

Ollama serving a local Qwen 3 model. `BRIEF.md` §12 has the specifics, the
gotchas, and the reason a small local model is an asset rather than a
compromise here: it fails in ways that make the harness's weak points
impossible to defer.

Set `options.num_ctx` low. That is how you provoke the compaction path cheaply.
