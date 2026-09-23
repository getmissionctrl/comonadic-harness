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
cabal test spec              # 24 examples: comonad, agreement, prefix, affordance,
                             #   compaction-rate, monoidal-scan, hostile-oracle, and
                             #   the AG-UI event/translate/sink/human-env/server specs
cabal run demo               # reproduces runs/oracle-output.txt (pure scripted oracle)
cabal run demo live          # same harness, live against Ollama on localhost:11434,
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
summary.

The task is seeded as the opening transcript turn (an empty prompt is what real
Ollama rejects). Flags: `--model M`, `--ctx N` (a small `--ctx` provokes the
compaction path; bump it for longer runs), `--budget N` (tokens; raise it so a
real read→write→commit can finish). Note the `--` after `live` so cabal passes
the flags to the demo rather than interpreting them itself.

Two guided reads, both typeset to committed PDFs:

- **The *how*** — `src/Harness/Tutorial.lhs`, a literate module walking the
  closed alphabet → `step` → `unfold` → the one interpreter → the tool-call cycle
  → the provider seam → the analysis gate. Its `>` code compiles as part of the
  build, so every example is guaranteed correct. Run `scripts/tutorial-pdf.sh`
  to (re)generate **`docs/tutorial.pdf`**.
- **The *why*** — `docs/motivation.md`, a standalone essay arguing the comonadic
  design against how coding agents are normally built. Run
  `scripts/motivation-pdf.sh` to (re)generate **`docs/motivation.pdf`**.

Per-symbol API reference lives in each module's Haddock; a pre-rendered HTML
snapshot of the whole API is committed under **`docs/api/`** (open
`docs/api/index.html`), regenerated with
`cabal haddock lib:comonadic-harness --haddock-hyperlink-source`.

### A note on the demo trace

`runs/oracle-output.txt` is the current `demo` output. At **step 9** the scripted
oracle emits a `commit` at a node where `commit` is not afforded (compaction has
wiped the earlier `write` from view). The coalgebra's admission pass (T6/D3)
*repairs* the unafforded call into a synthetic error observation rather than
performing it — so, unlike a pre-T6 recording, no `PERFORM commit` follows. The
divergence is the D3 behaviour demonstrated live, not a regression.

## AG-UI server

The harness is also exposed as a strict [AG-UI](https://docs.ag-ui.com) backend,
so any standard AG-UI client can watch and steer a run in real time over SSE. It
lives entirely in `Harness.AgUi.*` and a separate `serve` executable — the pure
comonadic core (`Alphabet`/`State`/`Coalgebra`/`Interp`) is untouched. Emission
is a tracing `Env` decorator (`Harness.AgUi.Sink.traceEnv`), not a change to the
alphabet: the same seam that carries retries and backoff (invariant 5) carries
AG-UI events, and `run` still reads only the shape.

```bash
cabal run serve            # listens on http://localhost:8080 (or: cabal run serve -- 9000)
```

Endpoints:

| method + path | body | what it does |
|---|---|---|
| `POST /agent` | a standard AG-UI `RunAgentInput` (`threadId`, `runId`, `messages`, …) | **the standard AG-UI transport.** Starts a run and streams the events back *on the same response* (`text/event-stream`), closing on `RUN_FINISHED`. This is what an off-the-shelf AG-UI client (assistant-ui, CopilotKit, `@ag-ui/client`) speaks. Sends permissive CORS |
| `POST /runs` | `{"task":"…", "mode":"auto"\|"human", "forecast":true\|false}` | our own two-step start; returns `{"runId","threadId"}`. `mode` and `forecast` are optional (default `auto`, `false`) |
| `GET /runs/{id}/events` | — | two-step SSE out-stream; replays the run's log from the start, then follows it live |
| `POST /runs/{id}/input` | `{"text":"…"}` | in `human` mode, supply the answer the blocked oracle is waiting on |

Conformance: events are strict AG-UI JSON, one object per SSE frame
(`data: {json}\n\n`), each with a SCREAMING_SNAKE `type` and camelCase fields —
`RUN_STARTED`/`RUN_FINISHED`, the `TEXT_MESSAGE_*` and `TOOL_CALL_*` sequences,
`TOOL_CALL_RESULT`, `STATE_SNAPSHOT`, and `STATE_DELTA` (an RFC-6902 JSON Patch,
e.g. `[{"op":"replace","path":"/budget","value":900}]`). The harness's own
signals — `harness.compaction` (an `Overflow` provoked a summarisation) and the
opt-in `harness.forecast` (`Harness.Probe.assess` predicting the run's future
before a token is spent) — ride on the standard `CUSTOM` event rather than
widening the event set.

v1 ships with a deterministic fake provider so the transport runs without a model
in the loop; wiring the live Ollama factory is a follow-up (see the `TODO(live)`
in `app-serve/Serve.hs`).

**UI smoke test.** `web/` is a minimal [assistant-ui](https://www.assistant-ui.com)
React app that drives the harness through `POST /agent` using the real
`@ag-ui/client` `HttpAgent` — proving the backend interoperates with a genuine
off-the-shelf AG-UI client, not just our own JS. `web/smoke.mjs` runs it headless
(Playwright) and asserts the harness's streamed reply renders. See `web/README.md`.
A dependency-free browser page for the two-step endpoints is in `static/smoke.html`.

## Environment

Ollama serving a local Qwen 3 model. `BRIEF.md` §12 has the specifics, the
gotchas, and the reason a small local model is an asset rather than a
compromise here: it fails in ways that make the harness's weak points
impossible to defer.

Set `options.num_ctx` low. That is how you provoke the compaction path cheaply.
