# Comonadic Harness — Module Design & Delivery Spec

**Date:** 2026-08-26
**Status:** approved design, pre-implementation
**Author:** Ben Ford (with Claude)

This spec adapts the already-complete design in `BRIEF.md` into a proper
Haskell project mirroring the `vf-haskell` flake/direnv/cabal conventions, and
sequences the delivery of tasks T1–T7. **It does not re-derive the comonadic
design** — `BRIEF.md` §§1–16 is the authority for *what* the harness is and
*why*; this document is the *how we package, build, test, and explain it*.

Provenance tags carry over from the brief: `[established]` (proved/cited/run
here), `[design]` (a defensible choice), `[speculative]` (untested), `[unbuilt]`
(named, not built).

---

## 1. Scope

- **Phase 1 = all of T1–T7** from `TASKS.md`, in order, each gate blocking the
  next.
- **Phase 2** (RecipeF → agent-AST morphism) is a forward-looking *stub
  document only*, no code. See §8.
- **Location:** standalone git repo, built **in place** at
  `/home/ben/dev/comonadic-harness`, alongside the existing `BRIEF.md`,
  `TASKS.md`, `CLAUDE.md`, `REFERENCES.md`, `reference/`, `runs/`, `docs/`.
- **Test environment:** Ollama serving a Qwen 3 model, running on the host
  **`hq`**. Development happens on **`scape`**. The provider therefore targets a
  **remote** base URL, never `localhost`.

---

## 2. Project shape & conventions

Mirror `vf-haskell`'s Nix idiom, deviating only where the brief's stricter
requirements demand it.

- **`default.nix`** — `{ pkgs }: pkgs.haskellPackages.callCabal2nix
  "comonadic-harness" ./. {}`. Identical pattern to `vf-haskell/default.nix`.
- **`flake.nix`** — `flake-utils.lib.eachDefaultSystem`, `nixpkgs` pinned to the
  same rev `vf-haskell` currently resolves (`0e251e24…`, nixos-unstable) so the
  dep set is known-good. Outputs:
  - `packages.default` = the library derivation.
  - `devShells.dev` = `pkg.env.overrideAttrs` adding `cabal-install`,
    `haskell-language-server`, `fourmolu`, `curl`, `jq`.
  - `devShells.default` = `dev`.
  - **Ollama is *not* in the flake** — it is a service on `hq` (T2). `curl`/`jq`
    are for poking the remote endpoint by hand.
- **`.envrc`** — `use flake` + `dotenv_if_exists .env`, matching the `os`
  monorepo idiom (`~/docs/1.Projects/Insurgnt/os/.envrc`).
- **`hie.yaml`** — cabal cradle over `src` / `app` / `test` (+ the literate
  component), same shape as `vf-haskell/hie.yaml`.
- **`.gitignore`** — `dist-newstyle/`, `result`, `.direnv/`, `*.hi`, `*.o`.
- **`CLAUDE.md`** — the existing working agreement stays; it already encodes the
  five invariants and the provenance convention.

### Side change: vf-haskell `.envrc`

`vf-haskell` currently has an empty `.envrc`. As a **separate, clearly-scoped
change in this pass**, add `use flake` to `/home/ben/dev/vf-haskell/.envrc` so
its dev shell auto-loads. This is the only edit to `vf-haskell`.

### Cabal specifics — follow the brief, not vf-haskell verbatim

`vf-haskell` builds on `GHC2021` with a modest extension set. This project needs
more (per `BRIEF.md` §11 and `TASKS.md` T1):

- `cabal-version: 3.0`.
- Components: library `harness`, executable `demo`, test-suite `spec`.
- Default extensions: `DeriveGeneric`, `DeriveFunctor`, `DeriveTraversable`,
  `DeriveAnyClass`, `LambdaCase`, `OverloadedStrings`, `OverloadedRecordDot`,
  `DataKinds`, `TypeApplications` (extend as the port needs, e.g. `DerivingVia`).
- `ghc-options: -Wall -Wcompat -Wincomplete-uni-patterns
  -Wredundant-constraints`. **Warnings are load-bearing**:
  `-Wincomplete-patterns` firing when a constructor is added is how the
  closed-alphabet discipline is enforced (`CLAUDE.md` invariant 1).
- **No Template Haskell anywhere.** Optics are generic-derived via
  `Optics.Generic` (`gfield`, `gconstructor`, `gplate`), never `optics-th`.
- Dependencies (verify bounds against what nix resolves, do not copy from
  memory): `base, comonad, free, optics-core, containers, text, bytestring,
  aeson, QuickCheck`, and `ollama-haskell >= 0.4.1.0` for the provider (§5) —
  which pulls in the HTTP/conduit stack transitively, so no direct
  `http-client` dependency is needed.

---

## 3. Module layout

```
comonadic-harness.cabal
default.nix  flake.nix  flake.lock  .envrc  hie.yaml  .gitignore
src/Harness/
  Alphabet.hs      HarnessF, Call, Obs, Request, Response, Refusal, Outcome,
                   Usage, ToolSpec, Prompt        -- the closed alphabet
  State.hs         S, Ctx, Mode, Turn; project, afford, request, view
  Coalgebra.hs     step, working, summarising, harness (= unfold view step)
  Interp.hs        interp  -- the UNIFIED interpreter (D9/§16.1)
  Run.hs           Env, run (= interp over the real oracle/world), withRetry
  Probe.hs         Hypo, Ev, probe (= interp in fuel-limited Writer [Ev]),
                   assess, Risk (+ generic Monoid, §16.3), governed
  Compaction.hs    compact (idempotent by fiat, D11); the compaction law as a
                   PRODUCT of observations (D10); respectsBehaviour
  Evolve.hs        evolve, outerLoop
  Tutorial.hs      pipes-style Haddock-only user guide (§7)
  Motivation.lhs   literate "why it is what it is" (§7), exposed module
src/Provider/
  Class.hs         Provider seam (the injected oracle; §8 of the brief)
  Ollama.hs        ollama-haskell provider on hq; optNumCtx; overflow (§5)
app/Main.hs        the demo run, reproduces runs/oracle-output.txt
test/              generators + laws + compaction violation-rate (§6)
docs/ollama-notes.md            filled from observation on hq (already stubbed)
docs/phase-2-recipe-morphism.md phase-2 stub (§8)
```

### The one structural change worth calling out: `Interp.hs`

The reference has `run` (in `Oracle.hs`) and `probe` (in `Oracle.hs`) as **two
hand-written `case` analyses over the same three `HarnessF` constructors**
(defect **D9**, `BRIEF.md` §16.1). The entire value proposition is that they
*agree* — `assess` is only worth computing if `probe` predicts `run`. That
agreement is currently maintained by inspection.

Unify them into one monad-parameterised interpreter:

```haskell
interp :: Monad m
       => (Request -> m (Either Refusal Response))   -- oracle side
       -> (Call    -> m Obs)                          -- world side
       -> Cofree HarnessF Ctx -> m Outcome

run   env = interp (oracle env) (world env)
probe h   = interp (pure . guessOracle h) (pure . guessWorld h)
            -- run in a fuel-limited Writer [Ev]
```

`probe`'s event emission and depth bound are **monadic effects, not extra
cases**. This makes the agreement law free by construction and satisfies the
closed-alphabet discipline in one place instead of two. Do it *in the port*
(T3), because every T4 law test depends on it.

The exact `interp` signature must reconcile "returns `Outcome`" (what `run`
wants) with "emits `[Ev]` and respects fuel" (what `probe` wants). Expected
shape: `interp` threads the effect and the outcome; `probe` layers `Writer` and
a fuel counter over it, with `run` using `Identity`-free `IO`/`m` directly. The
port must land a single `case` over `HarnessF`; if two remain, T3 is not done.

---

## 4. Invariants carried into this repo

From `CLAUDE.md` (these are correctness conditions, not style):

1. **The alphabet is closed.** No `HarnessF` constructor without a matching case
   in `interp` and the law tests. No wildcard matches there.
   `-Wincomplete-patterns` must fire when a constructor is added.
2. **`run`/`interp`-over-real-env never reads the annotation.** Execution
   consumes the *shape*; analysis consumes the *annotation*. A `Ctx` field that
   starts influencing execution belongs in `S` and `step`.
3. **`Cofree` is a denotation, not a runtime representation.** The
   implementation carries `S` and the coalgebra. Never serialise/cache the tree
   or hand it to the provider.
4. **Evolution lives outside the functor.** `HarnessF` must not mention `S`.
   Evolution is fold-then-reunfold (`evolve`/`outerLoop`), never an
   `Evolve` constructor.
5. **Transient failure never reaches the coalgebra.** 429/5xx/timeouts are
   absorbed below the coalgebra — here by `ollama-haskell`'s `configRetry`
   (`ExponentialRetry`), which subsumes the reference's hand-rolled `withRetry`.
   Only `Overflow` and terminal decode failures are `Refusal`.

---

## 5. Provider (T5) — remote Ollama on `hq` via `ollama-haskell`

**Library locked:** `ollama-haskell >= 0.4.1.0` (Hackage), native client. It
satisfies the load-bearing criterion — `Ollama.Types.Options.ModelOptions` has
`optNumCtx :: Maybe Int` with `defaultOptions` — so `num_ctx` is settable, which
the OpenAI-compat route could not guarantee. `[established]` — confirmed against
the 0.4.1.0 Haddock.

Three of its features map directly onto this design:

- **`configBaseUrl` / `clientFromEnv`** — point at `hq`. Either
  `withClient defaultConfig { configBaseUrl = "http://hq:11434" }` (base URL is
  **config**, never `localhost`), or `clientFromEnv` reading `OLLAMA_HOST`
  (set `OLLAMA_HOST=http://hq:11434` in `.env`, picked up via
  `dotenv_if_exists`).
- **`configRetry = ExponentialRetry n …`** — this *is* invariant 5. Transient
  failures (connection refused, 5xx, timeout) are absorbed by the library's
  retry, below the coalgebra, and must never surface as `Refusal`. It replaces
  the reference's hand-rolled `withRetry`. **Caveat:** ensure `Overflow` is
  *not* swallowed as a retryable error — it must reach the coalgebra as
  `Left Overflow` (see below).
- **`Ollama.Testing`** (pure mock) — the substrate for the T6/E4 hostile-oracle
  tests: feed it hallucinated tool names, malformed JSON, and empty responses
  without touching the network.

The provider implements the injected oracle seam
`oracle :: Request -> m (Either Refusal Response)` by:

1. translating our `Request` → `chatRequest model messages` with
   `chatTools = Just [...]` from `afford`, and the model options carrying
   `optNumCtx = Just <configured>`;
2. calling `chat client`;
3. translating the typed `ChatResponse`/error back into
   `Either Refusal Response`, mapping the usage token counts
   (`prompt_eval_count` → `Usage.inTok`, `eval_count` → `Usage.outTok`).

**Locked regardless:**

- Model tag is configuration; confirm the exact tag with `ollama list` on `hq`.
- `optNumCtx` is configuration and **deliberately settable low** — the single
  load-bearing lever: a low `num_ctx` provokes the `Overflow` → compaction path
  cheaply and repeatedly (T4/E1).
- **Determine overflow behaviour empirically** on the `hq` version: does Ollama
  truncate silently (infer `Overflow` by comparing the reported prompt-eval
  count against `num_ctx`) or return a decodable error? Record the answer, and
  which `ollama-haskell` error constructor surfaces it, with the version, in
  `docs/ollama-notes.md`. Do not assume.

The exact chat-request field carrying `ModelOptions`, the `ChatResponse` usage
field names, and the `Ollama.Error` constructor set are implementation-time
lookups (see Open items); the `optNumCtx` capability that gates the whole
approach is already confirmed.

---

## 6. Tests (T4, T6, T7)

Per `TASKS.md` T4, and expanded by the §16 review:

- **Generator discipline first (§16.7).** Never construct an `S` by filling in
  the record. Generate a sequence of oracle/world responses, run the harness,
  take the *reachable* states. Hand-written states can be unreachable, and a
  property checked on an unreachable state measures nothing. (This already bit
  the reference: `sampleS` gave a false `True`.)
- **Agreement law (§16.1):** `run (liftHypo h) w == outcomeOf (probe h ∞ w)`.
  Free by construction if T3 unified `interp`; assert it as a regression guard
  against re-splitting.
- **Prefix stability (§16.6):** `project (t : ts) == project ts <> renderLine t`
  in `Working` mode. This is what makes provider prompt-prefix caching sound; a
  well-meaning change breaks it with no other symptom.
- **Comonad laws** for `Cofree HarnessF Ctx` at bounded depth — free from
  `free`, asserted as a guard against a bad hand-written `Functor`.
- **Closed-alphabet:** no wildcard matches in `interp` or the law tests; comment
  each `case` saying so.
- **Affordance law (D12, §16.4):** `probe` never emits `Did c` whose tool is
  absent from the `Ctx` at that node. Expected to fail once a real model is
  wired (T5); that is the point.
- **Compaction law as a *product of observations* (D10, §16.2)** — not `[Ev]`
  equality. Four coarser observations, each with its own algebra:
  | observation | algebra | divergence means |
  |---|---|---|
  | halt outcome | `Last Outcome` | task ends differently |
  | irreversible actions | multiset of tool names | side effects gained/lost |
  | oracle call count | `Sum Int` | cost changed |
  | per-turn call sets | list of multisets | ordering-insensitive behaviour |
  Report a **violation rate** with per-component breakdown over ≥1000 reachable
  generated states. Baseline: a no-op `compact` must score 0%. **Failing
  informatively is the deliverable, not passing** (E1).
- **T6 / D3 / E4:** a hostile `Env` (hallucinated tool names, malformed JSON,
  empty responses) must produce **zero harness crashes**. Schema-invalid args
  are fed back as a synthetic `Obs` (keeps the alphabet at three constructors);
  argue the choice in a comment. Add the case to `probe` too.
- **T7 / D1 / E3:** make `Risk` a `Monoid` (derives generically from `Sum` /
  `Any` / multiset components, §16.3) and turn `governed` into a `scanr` over
  `tails` along the path a run traverses (linear along the path; still quadratic
  across the tree, which does not matter — a run visits one path). Deliverable: a
  before/after wall-clock curve against depth, **or** a written explanation of
  why the monoid does not exist for the wanted statistic. A negative result
  recorded is a result.

Every experiment gets a baseline null model. A number without one is not a
result.

---

## 7. The two explanation artifacts

Both draw from the same `harness` library, so neither can drift from real code.

### `src/Harness/Tutorial.hs` — the how (pipes-style)

Following `Pipes.Tutorial`:

- `{-# OPTIONS_GHC -fno-warn-unused-imports #-}`.
- `module Harness.Tutorial (-- * Section \n -- $sectionName …) where` — export
  list is Haddock anchors, **no top-level definitions**.
- Body is `{- $sectionName … -}` prose with `@ … @` inline code and `>>>` GHCi
  blocks.
- An `exposed-module`, so Haddock renders it in the Hackage docs and it
  typechecks against the real API.
- Arc: the closed alphabet → the coalgebra `step` → `unfold` → the
  shape/annotation split (`run` vs `governed`) → counterfactual annotation via
  `extend` → the compaction law. The library user's guide.

### `src/Harness/Motivation.lhs` — the why (literate, the direct answer)

- Literate Haskell (Bird-style `>` code), an **exposed library module**
  `Harness.Motivation`, so it compiles as part of `harness` and ships in the
  Hackage docs.
- The linear narrative that *derives* the harness and answers the originating
  (interview-shaped) question directly: "an agentic harness is a durable
  polynomial coalgebra…", why putting nondeterminism in the *directions* makes
  `duplicate` pure and lazy, what the comonad buys (counterfactual annotation),
  and why compaction gets a law. Real, compiling code interleaved with the prose
  it discusses.
- Where `Tutorial.hs` says *how to use it*, `Motivation.lhs` says *why it is what
  it is*.

Both are library modules → CI typechecks them → they cannot rot.

---

## 8. Phase 2 — kept in mind, not built

A single forward-looking stub, `docs/phase-2-recipe-morphism.md`, **no code**.
It sketches the intended morphism from `vf-haskell`'s `VF.Types.Recipe`
(`RecipeF`) to a `HarnessF`-program: turning ValueFlow value-flow business
models into executable Petri nets that hand processes — or portions of
processes — to the LLM through the `Render`/`Perform` alphabet and pass the
human-required bits back.

It names:
- **The seam:** `VF.Types.Recipe` (vf-haskell) ↔ the agent AST here.
- **The open question:** where the human-in-the-loop boundary sits — likely a
  *fourth interpretation* of the same alphabet (alongside `run` and `probe`),
  **not** a new `HarnessF` constructor (invariant 1; `CLAUDE.md`). This keeps
  §7 evolution and §13 driver-side (`Free`/`Sum`/`Day`) considerations honest
  without pulling them into phase 1.

`[unbuilt]` throughout.

---

## 9. Delivery sequence (T1–T7)

Each acceptance criterion (from `TASKS.md`) gates the next task.

1. **T1 cabal** — `cabal build` succeeds on an empty-ish `harness` stub.
2. **T2 flake + `.envrc`** — `nix develop` gives a shell where `cabal build`
   works and `curl http://hq:11434/api/tags` returns the model list from inside
   it. *(Also: add `use flake` to vf-haskell's `.envrc`.)*
3. **T3 port** — reference `Oracle.hs` (+ `outerLoop`/`respectsBehaviour` from
   `Harness.hs`) rewritten into `src/Harness/*`: real `free`/`comonad`,
   `Generic` on every record and sum, `Optics.Generic` composition in `step`
   (no TH), **unified `interp` (D9)**, generic `Risk` `Monoid` (§16.3),
   idempotent-by-fiat `compact` (D11). Accept: `-Wall` clean, one `case` over
   `HarnessF`, `app/Main.hs` reproduces `runs/oracle-output.txt` modulo
   formatting (diff the traces).
4. **T4 law tests** — generators through public transitions; the laws above;
   compaction violation-rate over ≥1000 reachable states with per-component
   breakdown. Accept: it runs and reports a classified rate. Expected to fail;
   failing informatively is the deliverable.
5. **T5 provider** — remote Ollama on `hq` per §5. Accept: a real end-to-end run
   completes, and a low-`num_ctx` run visibly traverses
   `Working → Summarising → Working` (as in `oracle-output.txt` nodes 6–8).
6. **T6 D3** — hostile `Env` → zero harness crashes (E4).
7. **T7 D1** — monoidal-scan `governed`; before/after curve or a written
   negative result (E3).

Then: `Tutorial.hs` and `Motivation.lhs` written against the settled API (they
can be drafted alongside T3 and kept in sync as the API firms up).

---

## 10. Explicitly declined (so it is not relitigated)

From `BRIEF.md` §16.8: GADT-indexed alphabet (the continuation's argument type
*is* the polynomial structure); phantom-tagged `S (m :: Mode)` (would force an
existential from `step`); indexed monad for a balance invariant (no conservation
law — the token budget is monotone-decreasing, not balanced); promoted units
(one dimension, tokens); first-class families. QuickSpec: at most one
exploratory run over `compact`/`step`/`project`, not a first move.

---

## Open items to verify during implementation (not blockers)

- Whether `ollama-haskell 0.4.1.0` is in the pinned nixpkgs `haskellPackages`;
  if not, add it as an overlay/`callHackageDirect` in `default.nix` (§2, §5).
- The exact chat-request field carrying `ModelOptions`, the `ChatResponse`
  usage-count field names, and the `Ollama.Error` constructor that surfaces
  overflow (§5). `optNumCtx` itself is already confirmed present.
- Exact `interp` signature reconciling `Outcome` return with `Writer [Ev]` +
  fuel (§3).
- Ollama overflow behaviour and `num_ctx` default on the `hq` version (§5,
  `docs/ollama-notes.md`).
- Whether `Cofree`/`unfold` from `free` wants `coiter` or the
  `(s -> a) -> (s -> f s) -> s -> Cofree f a` unfold shape (T3 item 1).
