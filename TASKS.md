# Tasks

Ordered. Each has an acceptance criterion. Do not start a task until its
predecessor's criterion is met. Read `BRIEF.md` first; section references below
point into it.

---

## T1. Cabal file

Create `comonadic-harness.cabal`. Library `harness` plus an executable `demo`
and a test-suite `spec`.

Dependencies:

```
base, comonad, free, optics-core, containers, text, bytestring,
aeson, http-client, http-client-tls, QuickCheck
```

Default extensions to consider: `DeriveGeneric`, `DeriveFunctor`,
`DeriveTraversable`, `DeriveAnyClass`, `LambdaCase`, `OverloadedStrings`,
`OverloadedRecordDot`, `DataKinds`, `TypeApplications`.

`ghc-options: -Wall -Wcompat -Wincomplete-uni-patterns -Wredundant-constraints`.
Warnings are not optional in this project; the closed-alphabet discipline
depends on `-Wincomplete-patterns` firing when a constructor is added.

Optics are generic-derived via `Optics.Generic`. **No `optics-th`, no Template
Haskell anywhere in this project** — it complicates the nix build for no
benefit here.

**Check what nix actually resolves before writing version bounds.** Do not copy
them from memory.

**Accept when:** `cabal build` succeeds on an empty-ish library stub.

---

## T2. Nix flake

`flake.nix` with a `devShell` (GHC, cabal-install, HLS, ormolu or fourmolu) and
a package output. Nixpkgs `haskellPackages` is fine; `haskell.nix` is
acceptable if you prefer it, but justify the extra complexity in a comment.

`ollama` does **not** need to be in the flake — it runs as a service on the
host. Do add `curl` and `jq` to the devShell for poking at the endpoint by hand.

**Accept when:** `nix develop` gives a shell where `cabal build` works, and
`curl http://localhost:11434/api/tags` returns the model list from inside it.

---

## T3. Port the reference code with `Generic` and real libraries

Port `reference/*.hs` into `src/Harness/` per the layout in §11. This is a
rewrite, not a copy. Changes required:

1. Delete the hand-rolled `Cofree`. Use `Control.Comonad.Cofree` from `free`
   and the `Comonad` class from `comonad`. The hand-rolled `unfold` is
   `Control.Comonad.Cofree.unfold` or `coiter` — check which signature you
   want; the reference wants `(s -> a) -> (s -> f s) -> s -> Cofree f a`.
2. Everything derives `Generic`. Every record and every sum.
3. Replace record-update syntax in `step`, `working`, `summarising` with optic
   composition. This is the main readability win: `step` currently reads as a
   pile of field updates and should read as a state transition.
4. Prisms for `HarnessF`, `Refusal`, `Outcome`, `Turn`.
5. Take the `Oracle.hs` version as the base, not `Harness.hs` — it has the
   three amendments (§8). `Harness.hs` is kept only because it contains
   `outerLoop` and `respectsBehaviour`, which `Oracle.hs` does not.
6. **Unify `run` and `probe` into one interpreter** (§16.1, defect D9). They
   are currently two hand-written case analyses over the same alphabet, and
   the law that they agree is the entire value proposition. Factor both
   through a single monad-parameterised `interp`; `probe` runs it in a
   fuel-limited `Writer [Ev]`. Do this in the port, not afterwards — every
   law test in T4 depends on it.
7. Derive `Risk`'s `Monoid` generically from its component monoids (§16.3).
   It exists; do not hand-write it.
8. Make `compact` idempotent by fiat in a smart constructor (§16.5, D11).

**Accept when:** `-Wall` clean, `run` and `probe` share one interpreter with
no duplicated `case` over `HarnessF`, and `app/Main.hs` reproduces
`runs/oracle-output.txt` modulo formatting. Diff the traces.

---

## T4. Law tests

`test/` with, at minimum:

- **Generator discipline first (§16.7).** Never construct an `S` by filling in
  the record. Generate a sequence of oracle and world responses, run the
  harness, and take the reachable states it produces. Hand-written states can
  be unreachable, and testing compaction on a state the coalgebra cannot
  produce measures nothing. This bit us already: the `sampleS` in
  `reference/Run.hs` returned a false `True`.

- **The agreement law (§16.1).** `run (liftHypo h) w == outcomeOf (probe h ∞ w)`.
  If T3 item 6 was done properly this is free by construction, so assert it as
  a regression guard against someone re-splitting the interpreter.

- **Prefix stability (§16.6).** `project (t : ts) == project ts <> renderLine t`,
  in `Working` mode. This is what makes provider prompt-prefix caching sound,
  and it will be broken by a well-meaning change with no other symptom.

- **Comonad laws** for `Cofree HarnessF Ctx` at bounded depth. These come free
  from `free`, but assert them as a guard against a bad hand-written `Functor`
  instance on `HarnessF`.

- **Closed-alphabet test (§15).** No wildcard matches in `interp` or the law
  tests, so `-Wincomplete-patterns` fires when a constructor is added. Comment
  at each `case` saying so.

- **The affordance law (§16.4, D12).** `probe` never emits `Did c` whose tool
  is absent from the `Ctx` at that node. Expected to fail once a real model is
  wired in T5; that is the point.

- **The compaction law as a *product* of observations (§16.2, D10),** not
  `[Ev]` equality. Halt outcome, multiset of irreversible actions, oracle call
  count, per-turn call sets. Each component that differs names a divergence
  kind, so E1's classification comes from the structure rather than being
  bolted on. Report a violation **rate** with the breakdown. Baseline: a no-op
  `compact` must score 0%.

**Accept when:** the compaction property runs over ≥1000 reachable generated
states and reports a rate with a per-component classification. It is expected
to fail; failing informatively is the deliverable, not passing.

---

## T5. Ollama provider

`src/Provider/Ollama.hs`. Implement `Provider` (§8, §12) against
`POST http://localhost:11434/api/chat`.

Required behaviour:

- Model tag is configuration, not a literal. Confirm with `ollama list`.
- `options.num_ctx` is configuration and is deliberately settable low, because
  that is how you provoke `Overflow` cheaply (§12).
- Map `prompt_eval_count` / `eval_count` to `Usage`.
- **Determine empirically how overflow presents.** Send a prompt longer than
  `num_ctx` and observe. If Ollama truncates silently, `Overflow` must be
  inferred by comparing `prompt_eval_count` against `num_ctx`. If it errors
  cleanly, decode the error. Write down which it was, with the version number,
  in `docs/ollama-notes.md`. Do not assume.
- Transient failures (connection refused, 5xx, timeout) go through `withRetry`
  and must never surface as `Refusal`.

**Accept when:** a real end-to-end run against local Ollama completes, and a
second run with `num_ctx` set low visibly traverses the
`Working -> Summarising -> Working` path in the trace, as in
`runs/oracle-output.txt` nodes 6–8.

---

## T6. Fix D3, the malformed-tool-argument case

Small models will hallucinate tool names and emit invalid argument JSON at a
non-trivial rate. The correct response is neither `Refusal` nor a clean
`Response`: it is to feed the validation error back as a tool result and let
the model retry.

Decide where this goes. Two candidates:

- A `Response` whose `calls` include a call that fails schema validation, with
  validation happening in `step` and producing a synthetic `Obs`.
- A third `Refusal`-like case that the coalgebra handles by appending a
  corrective turn.

The first keeps the alphabet at three constructors and is probably right, but
argue it in a comment rather than assuming. Whatever you choose, add the case
to `probe` too (§15).

**Accept when:** E4 (§14) — a deliberately hostile `Env` emitting hallucinated
tool names, malformed JSON, and empty responses — produces zero harness
crashes.

---

## T7. D1, the quadratic `extend`

`assess` re-probes from scratch at every node. Make `Risk` a `Monoid` and turn
`extend` into a scan so the annotation carries the accumulated statistic.

**This may not be possible** for every statistic you want (§10). If the monoid
does not exist, fall back to bounded-horizon memoisation, document why, and
move on. A negative result recorded is a result.

**Accept when:** E3 (§14) has a before/after wall-clock curve against depth,
or a written explanation of why the monoid does not exist.

---

## Later, not now

- D2, `Hypo` as a sampler (`Risk` becomes a distribution). Wait for E2 to
  justify it.
- D5, transcript as a tree with branching and navigation.
- D4, `persist` and replay-safety annotations on `Call`.
- Queues and steering seams (§9).
- The driver side, `Free`/`Sum`/`Day` (§13). Do not build until something
  forces it.
