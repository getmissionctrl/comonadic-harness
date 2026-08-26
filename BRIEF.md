# A Comonadic Agentic Harness

Design brief and handover. Everything here was derived in conversation and
validated by compiling and running the code in `reference/`. Provenance is
tagged throughout:

- `[established]` — proved, cited, or demonstrated by running code in this repo
- `[design]` — a choice made, defensible but not forced
- `[speculative]` — plausible, untested, may be wrong
- `[unbuilt]` — named, not implemented

---

## 1. The claim

An agentic harness is a **durable polynomial coalgebra over a closed action
alphabet, equipped with three lossy quotients and one unreliable oracle
boundary.** `[design]`

The comonad `Cofree HarnessF Ctx` is the *denotation* of that coalgebra: the
lazily-unfolded tree of every reachable state. It is not the runtime
representation. You implement the coalgebra and reason with the comonad.
`[established]` — see `reference/Harness.hs`.

The move that makes the comonad honest in an effectful setting is putting the
nondeterminism in the **directions** rather than the positions:

```haskell
data HarnessF x
    = Render  Request (Either Refusal Response -> x)
    | Perform Call    (Obs -> x)
    | Halt    Outcome
    deriving (Functor)
```

The harness is deterministic. It always knows what it does next. What it does
not know is what comes back. So `duplicate` is pure and lazy: a branch is a
function, not an effect, and materialising one costs nothing. `[established]`

The standard objection — "`duplicate` is free in a UI because it is pure, but
an agent must run tools to see its futures" — dissolves under this shaping.
The tree branches on *unobserved inputs*, not on *unperformed effects*.

---

## 2. Why this rather than the existing designs

Two production harnesses were read in detail. Neither mentions comonads and
neither needs to in order to work. `[established]`

**`earendil-works/pi`** (TypeScript). `agent-loop.ts` is 796 lines with about
thirty lines of actual control flow; `agent-session.ts` is 3,478. The
structurally load-bearing parts:

- `peekAction()` / `executeAction()` on `AgentLane` — the two projections of a
  coalgebra, deliberately separated, with `drive: "automatic" | "manual"` as
  the switch between the coalgebra and its unfolding
- `ActionInfo`, a closed sum of fifteen constructors — the interface functor,
  arrived at empirically. Roughly half are transcript bookkeeping
- `reduceLaneState`, a pure fold from a durable record log to `LaneState`, with
  a twelve-case `RecordLogCorruption` taxonomy naming log states the
  single-writer protocol cannot produce
- `SuspendedOperation` carrying `reason: "crash" | "deferred"` and
  `missing: { tools, models }` — resume can fail because the environment no
  longer supplies capabilities the log references
- `replay?: "never" | "safe"` on `HarnessTool` — effects are not uniformly
  replayable

**`lucasdicioccio/agents-exe`** (Haskell, 58k lines, of which the harness is
about 660). `Session/Base.hs`, `Session/Step.hs`, `Session/Loop.hs`:

```haskell
data Action r = Stop r | AskUserPrompt MissingUserPrompt
              | AskLlmCompletion LlmCompletion | Evolve (Agent r)
              deriving (Functor)

data Agent r = Agent { step :: Session -> IO (Action r), ... } deriving (Functor)
```

A four-constructor alphabet against pi's fifteen, `step` as the coalgebra, and
`Loop.run` as a six-line anamorphism. `naiveTilNoToolCallStep` is a thirty-line
pure case analysis and is the entire control flow of a coding agent.

Its distinctive feature is `Evolve (Agent r)`, structural revision as a
first-class action. The source carries a candid comment: forking was rejected
because it would need a joining function `r -> r -> r`, which would break the
`Functor` instance. **That is the same wall this design hits from the other
side**, and it is why evolution here lives *outside* the functor (§6).

Neither has compaction as a first-class concept with a stated correctness
condition. agents-exe has no compaction at all; `Session/Signals.hs` computes
stagnation and near-duplicate detection over turn windows, which is diagnosis
without the corresponding rewrite. `[established]`

The `Contravariant` in agents-exe is not structural: it is `Prod.Tracer`
logging, `contramap MyTrace tracer`, threaded through every module. Orthogonal
to the coalgebra, and correctly so — streaming and tracing are presentation
concerns. `[established]`

---

## 3. The minimal definition

**State `S`.** A transcript that is a tree, not a list, with addressable nodes.
(The reference code uses a list; see Defect D5.) Branching is what makes it a
state rather than a log, because you need to name a point and resume from it.

**Alphabet `Σ` and its result family.** For each action `σ`, a type `Obs(σ)` of
what performing it returns. Mode-dependent in two ways: which actions are legal
depends on `s`, and the observation type depends on `σ`. That dependence is
what makes the shape polynomial, `p(X) = Σ_{σ ∈ Σ(s)} X^{Obs(σ)}`, and it is why
a fixed product of handlers will not type it. `[established]`

**Coalgebra.** `step :: S -> HarnessF S`.

**Three quotients on `S`:**

| quotient | type | lossy? | role |
|---|---|---|---|
| `project` | `S -> Request` | yes | what the model sees |
| `compact` | `S -> S` | yes | what the harness keeps |
| `persist` | `S -> Bytes` | no | what survives a crash |

**Oracle boundary.** `oracle :: Request -> m (Either Refusal Response)`,
external, nondeterministic, flaky, rate-limited, and explicitly not part of the
harness. The correctness obligation is to behave well for an *arbitrary*
oracle, including an adversarial one.

That is the whole thing. Everything else in pi and agents-exe reduces to one of
these or is contingent (§8).

---

## 4. The four moves, in code

1. **Alphabet.** `HarnessF`, closed, three constructors.
2. **Coalgebra.** `step :: S -> HarnessF S` — the case analysis.
3. **Unfold.** `harness = unfold view step` — the only constructor for a
   harness, so no `Cofree HarnessF Ctx` exists that is not generated by some
   coalgebra.
4. **Run.** The pairing against an effectful environment, five lines:

```haskell
run env (_ :< f) = case f of
    Halt o      -> pure o
    Render q k  -> oracle env q >>= run env . k
    Perform c k -> world  env c >>= run env . k
```

`run` never touches the annotation. **Execution consumes the shape; analysis
consumes the annotation.** That split is the point of the whole construction.
`[established]`

---

## 5. What the comonad buys: counterfactual annotation

You cannot fold an infinitely-branching tree. You can fold it under a
*hypothesis* — a pure stand-in for the oracle and the world — which collapses
branching to a path:

```haskell
probe   :: Hypo -> Int -> Cofree HarnessF Ctx -> [Ev]
assess  :: Hypo -> Int -> Cofree HarnessF Ctx -> Risk
governed h n = extend (assess h n)   -- :: Cofree HarnessF Risk
```

`governed` annotates **every reachable state** with a counterfactual assessment
of its own future, from a function that only knows how to assess one position.
`extract (governed h 32 w)` is the pre-action gate at the current node.
`[established]` — see `runs/oracle-output.txt`, where the root annotation
forecasts 17 steps, termination, five irreversible writes, and two compaction
events before a single token is spent.

The forecast is only as good as `Hypo`. In the recorded run it gets the shape
right and the content wrong. The comonad supplies the plumbing to attach
forward-looking assessment cheaply; it does not supply a model of the oracle.
That is a separate and harder problem. `[established]`

---

## 6. Compaction, and its correctness condition

This is the load-bearing result.

The law you want is that compaction is a **coalgebra homomorphism**:

```
step (compact s)  ==  fmap compact (step s)
```

Equivalently: `s` and `compact s` are bisimilar; equivalently, `unfold` factors
through `compact`. `[established]` — standard coalgebra, see Rutten.

You cannot check that directly, because `HarnessF S` contains functions. You
check its observable shadow. And the shadow is *sharper* than the naive
statement: since compaction must change the prompt, the equivalence has to be
on the **action trace with `Asked` opaque**, never on the rendered context.

> **Compaction is correct exactly when it is invisible in what the agent does,
> not in what it sees.** `[design]`

`respectsBehaviour` in `reference/Harness.hs` implements this and correctly
returns `False` for a compaction that manufactures an irreversible write:

```
before:  [Asked, Ended Done]
after:   [Asked, Did write, Asked, Ended Done]
respects behaviour? False
```

**Important caveat, learned the hard way.** The first sample state I tried
returned `True` by coincidence, because compacted and uncompacted happened to
sit on the same side of the hypothesis threshold. The property is
state-dependent. Checking it at one state proves nothing. This wants QuickCheck
over generated transcripts and a *violation rate*, not a boolean. `[established]`

The quantitative generalisation is a **behavioural pseudometric on the final
coalgebra** (Desharnais et al.; van Breugel and Worrell), which would give
"how badly did this compaction hurt" rather than a yes/no. The framework
exists; applying it here is untested. `[speculative]`

---

## 7. Evolution: the outer loop

Changing the coalgebra cannot be a constructor of `HarnessF`, because the
functor must not mention `S`. This is exactly the wall agents-exe hits with
`Evolve (Agent r)`. `[established]`

So evolution is **fold-then-reunfold**: keep `S`, swap the coalgebra, `unfold`
again. Inner loop unfolds a fixed machine; outer loop replaces the machine.
`outerLoop` in `reference/Harness.hs` demonstrates it: a coalgebra that never
halts cleanly is rejected on the basis of `terminates (assess ...)` — reading
the *future* of a machine that has not been run — and the next one is unfolded
from the same seed. `[established]`

This is destruction-creation with a computed trigger rather than a guessed one.

---

## 8. Where the LLM lives

`Env.oracle`. One field, consumed by one line of `run`. Wiring a real provider
forced three amendments, all in `reference/Oracle.hs`:

**A1. `Render` was under-specified.** It carried a `Prompt`. A provider needs
tool definitions. `afford` was computing the mode-dependent tool set into the
*annotation*, which `run` explicitly ignores, so the affordances were
calculated and thrown away. `Render` now carries a `Request`. `[established]` —
this was a real bug.

**A2. Which failures the coalgebra may see.** `Either Refusal Response`, where
`Refusal = Overflow | Malformed`. Transient failure (429s, 5xx, timeouts) is
`Env`'s problem and is handled by a decorator, because retrying does not change
the state. Overflow *must* reach the coalgebra, because the only correct
response is a state transition and the coalgebra is the only thing that can
make one. `[design]`

**A3. Budget in tokens**, from the provider's reported usage, not a turn
counter.

**And the payoff:** compaction needs a summarisation call, and it goes through
the same `Render` constructor. The alphabet does not grow.

```haskell
(Working,     _) -> Render (request s) (working s)
(Summarising, _) -> Render (request s) (summarising s)
```

`request` supplies a summarisation prompt and *no tools* when summarising.
Watch it in `runs/oracle-output.txt` nodes 6–8: overflow, summarisation call
with an empty tool list, context collapsing from eight lines to one at a cost
of 320 tokens — and the `commit` affordance vanishing, because compaction
erased the write that granted it. Compaction destroying a capability, visible
in the type rather than as a mystery. `[established]`

---

## 9. What is contingent

Not part of the definition; each reduces to something already present.

- Streaming, tracing, telemetry → presentation, contravariant, orthogonal
- Retry policy → the oracle being flaky, an `Env` decorator
- Model cycling, thinking levels, auth → parameters of `Env`
- Skills, prompt templates → macros feeding `project`
- Hooks (pi has eleven) → `project` and the effect interpreter left open to
  extension; they add no structure
- Lanes → concurrent coalgebras over a shared tree with a single-writer lock

**Borderline: queues.** pi has three (`steer`, `followUp`, `nextRun`),
distinguished only by *when* they are drained. "The enumerable seams at which
external input may enter" is a real part of the specification and picking them
wrong produces incoherent transcripts. Keep them, as a refinement of a
`Consume` action rather than a new component. `[design]`

---

## 10. Known defects in the reference code

| id | defect | severity |
|---|---|---|
| D9 | `run` and `probe` are two hand-written interpretations of the same alphabet. The agreement law between them is the whole value proposition and is unstated, unchecked, and maintained by inspection. See §16.1 | **highest** |
| D10 | `respectsBehaviour` compares `[Ev]` by `==`. Too strong (calls within a turn are unordered) and too coarse (no divergence classification). See §16.2 | high |
| D7 | `respectsBehaviour` checks one state; needs property-based quantification, with states generated through public transitions only (§16.7) | high |
| D2 | `Hypo` is a deterministic function; it should be a sampler, making `probe` return a distribution over traces and `Risk` a statistic over it | high |
| D1 | `assess` re-probes from scratch at every node, so `governed` is quadratic in depth. **Correction:** the `Monoid` on `Risk` does exist and derives generically; the memoisation is a `scanr` over `tails` and is valid along the path a run traverses, which is enough. See §16.3 | medium |
| D3 | No third case for schema-invalid tool arguments. Real providers emit them at a few percent; the correct response is to feed the validation error back as a tool result, which is neither `Refusal` nor clean `Response`. The only place the three-constructor alphabet is genuinely under-powered rather than terse | medium |
| D12 | `step` takes `pending = calls r` unchecked, so the coalgebra can `Perform` a call that `afford` never offered. Needs a smart constructor and a law. See §16.4 | medium |
| D4 | No `persist`, no replay-safety annotation on `Call`. Crash recovery would re-perform everything | medium |
| D5 | `transcript` is a list, not a tree. No branching, no `navigateTree`, no forking | medium |
| D11 | `compact` is not idempotent for transcripts shorter than two turns. Enforce by fiat. See §16.5 | low |
| D6 | No concurrency, queues, or steering seams | low |
| D8 | `Cofree` hand-rolled to keep the sketch base-only. Replace with `Control.Comonad.Cofree` | trivial |

**D1's fix**, corrected by §16.3: `Risk`'s `Monoid` derives from its component
monoids (`Sum`, `Any`, free monoid) via `Generic`. Under a `Hypo` the branching
tree collapses to a stream, and `extend` on a stream with a monoidal statistic
is a `scanr` over `tails`. Linear along any single path; still quadratic across
the tree, which does not matter because a run visits one path. `[established]`

The hedge that appeared here in an earlier draft — "the monoid may not exist" —
was wrong for `Risk` as currently written. It becomes true again under D2, when
`Risk` becomes a distribution rather than a tuple of scalars.

---

## 11. Target architecture

```
comonadic-harness/
├─ comonadic-harness.cabal          <- TASK 1
├─ flake.nix                        <- TASK 2
├─ src/Harness/
│  ├─ Alphabet.hs      HarnessF, Call, Obs, Request, Response, Refusal, Outcome
│  ├─ State.hs         S, Ctx, Mode, Turn; project, afford, view
│  ├─ Coalgebra.hs     step, working, summarising, harness
│  ├─ Run.hs           Env, run, withRetry
│  ├─ Probe.hs         Hypo, Ev, probe, assess, Risk, governed
│  ├─ Compaction.hs    compact, respectsBehaviour, the law as a property
│  └─ Evolve.hs        outerLoop
├─ src/Provider/
│  ├─ Class.hs         Provider, the injected post/decode seam
│  └─ Ollama.hs        the local provider (§12)
├─ test/               law tests, property tests
└─ app/Main.hs         the demo runs
```

### Dependencies to bring in

- **`comonad`** — `Comonad`, `ComonadApply`. Replaces the hand-rolled class.
- **`free`** — `Control.Comonad.Cofree` for `Cofree`, `unfold`/`coiter`.
  Also `Control.Monad.Free` for the *driver* side; see §13.
- **`optics-core`** — lenses over `S` and `Ctx`, prisms over `HarnessF`,
  `Refusal`, `Outcome`. `step` is currently a pile of record updates and reads
  much better as optic composition.
- **`base`**, plus `containers`, `text`, `bytestring`, `aeson`, `http-client`,
  `http-client-tls` for the provider.
- **`QuickCheck`** / **`hedgehog`** for D7 and the compaction law.

### Generic derivation

Everything derives `Generic`. Optics come from `Optics.Generic` in
`optics-core` — `gfield`, `gafield`, `gconstructor`, `gplate`. **No Template
Haskell, no `optics-th`.** `[design]`

That means `gfield @"budget"` and `gconstructor @"Overflow"` rather than
generated `#budget` labels. If `#label` syntax turns out to be worth it, wire
it with a generic `LabelOptic` instance rather than reaching for TH; but do not
do that speculatively, since it costs an overlapping instance and buys only
syntax.

Extensions likely needed: `DeriveGeneric`, `DeriveFunctor`, `DeriveTraversable`,
`DeriveAnyClass`, `OverloadedRecordDot`, `DataKinds`, `TypeApplications`,
`LambdaCase`.

---

## 12. The local model: Ollama

Target environment is Ollama serving a Qwen 3 model locally. Two endpoints:

- `POST http://localhost:11434/api/chat` — native, supports a `tools` array
- `POST http://localhost:11434/v1/chat/completions` — OpenAI-compatible; wants
  a dummy `Authorization: Bearer ollama`

Prefer the native endpoint. Tool-calling support is model-dependent; Qwen 3
supports it. **Confirm the exact tag with `ollama list` before hardcoding
anything**, and keep the model string a config parameter.

Three practical notes, all needing verification against your installed version:

1. **`options.num_ctx` controls the context window** and defaults low. This is
   the single most useful lever in this project: *set it small and you can
   provoke the `Overflow` path cheaply and repeatedly*, which makes the
   compaction experiments (§14, E1) fast and local. Do this deliberately.
2. **Ollama historically truncated the prompt silently** rather than erroring
   on overflow. If so, `Overflow` cannot be detected from an error and must be
   inferred by comparing `prompt_eval_count` against `num_ctx`. Verify current
   behaviour; if it now errors cleanly, that is better and simplifies
   `decode`. `[speculative]`
3. **Usage fields**: `prompt_eval_count` and `eval_count` map to
   `Usage { inTok, outTok }`.

Small local models fail in ways frontier models mostly do not: malformed tool
JSON, hallucinated tool names, calls to tools not in the affordance list. That
is a feature for this project. It makes D3 impossible to defer and gives you a
cheap adversarial oracle to test the "behave well for an arbitrary oracle"
obligation.

---

## 13. Optional: the driver side

Not required, but the structure is there. `Co (Cofree f) ≅ Free f` under
conditions on `f`, so the pairing partner of the harness comonad is a free
monad over the dual interface — the language of legal driving programs.
`free` gives you both halves. `[established]` — Freeman, *The Future Is
Comonadic*; Kmett, *Monads from Comonads*.

Composition operators from the same source, both preserving the comonad:

- `Data.Functor.Sum` — one-at-a-time switching with a bit saying which is
  live. This is permission modes and plan/execute/review phases.
- `Data.Functor.Day` (in `kan-extensions`) — two components evolving
  independently with a joint render. This is parallel subagents.

Neither is needed for the core. Do not build them until something forces it.
`[unbuilt]`

---

## 14. Experiment programme

Each experiment has a designed failure mode that triggers the next decision.
Baseline null models are required.

**E1 — compaction defect rate.** QuickCheck over *reachable* generated states
(§16.7); measure the fraction where the compaction observation differs,
classified by which component observation diverged (§16.2): halt outcome,
irreversible-action multiset, oracle call count, per-turn call sets. Baseline:
a no-op `compact`, which must score 0%.
- *Predicted failure:* defect rate is high and dominated by extra irreversible
  actions. → compaction must be gated on irreversibility, not on token count.
- *If instead* defects are dominated by missed halts → the problem is the halt
  predicate reading the transcript rather than a separate flag, and D5 becomes
  urgent.
- **Cost model note (§16.6):** compaction does not only lose information, it
  invalidates the provider's prompt prefix cache. Include the cache-miss cost
  of the next turn alongside the summarisation call's own tokens, or the
  measured cost of compaction will be understated.

**E2 — does the gate beat a static budget?** Treatment: abort when
`assess` predicts `not terminates` or more than *k* irreversible actions.
Baseline: fixed step cap at the same expected cost. Metric: task completion
rate and count of unwanted irreversible actions.
- *Predicted failure:* the gate loses, because `Hypo` is too crude (D2). →
  that result is what justifies building the sampler.

**E3 — `extend` cost.** Measure `governed` wall-clock against depth before and
after the monoid/scan rewrite (D1).
- *Predicted failure:* the monoid does not exist for the statistic you want. →
  fall back to bounded-horizon memoisation and accept the constant factor.

**E4 — arbitrary-oracle robustness.** Drive the harness with a deliberately
hostile `Env`: hallucinated tool names, malformed JSON, empty responses,
responses that ignore the tool list. Count harness crashes. The correctness
obligation says this should be zero.
- *Predicted failure:* D3 bites immediately.

---

## 15. Discipline

- The alphabet stays closed. No constructor is added without a corresponding
  case in `probe`, in `run`, and in the law tests. If you find yourself wanting
  an escape hatch, that is the signal the state is missing a field.
- `run` must never read the annotation. Execution uses shape, analysis uses
  annotation. If that separation breaks, the construction has no value.
- `Cofree` is a denotation. Do not make it the runtime representation. The
  implementation carries `S` and the coalgebra; the tree is what you reason
  with.
- Evolution lives outside the functor. If you are tempted to add
  `Evolve (S -> HarnessF S)`, re-read §7 and agents-exe's comment about the
  joining function.
- Every experiment gets a baseline null model. A number without one is not a
  result.
- Do not let the vocabulary outrun the construction. "Polynomial", "bisimilar",
  and "coalgebra homomorphism" are used above because there are corresponding
  definitions in the code. If a claim loses its referent during refactoring,
  delete the word.

---

## 16. Type-driven and algebra-driven review

A pass over `reference/Oracle.hs` and `reference/Harness.hs` against the
`vf-haskell` TwT/ADD guide. Findings are ordered by payoff, cheapest first,
matching that guide's own convention. Four of these are real defects and are
added to §10 as D9 through D12.

### 16.1 `run` and `probe` are two interpretations of one alphabet

Both are hand-written case analyses over the same three constructors:

```haskell
run   env    (_ :< f) = case f of Halt o -> ...; Render q k -> ...; Perform c k -> ...
probe h n    (_ :< f) = case f of Halt o -> ...; Render q k -> ...; Perform c k -> ...
```

ADD's observations-first framing makes the problem obvious. `run` and `probe`
are the two observations out of the harness algebra, and the **entire value
proposition of this design is that they agree**: `assess` is only worth
computing if `probe` predicts `run`. That agreement is currently maintained by
inspection, in two places, with no law.

The law that should hold:

```
run (liftHypo h) w  ≡  outcomeOf (probe h ∞ w)
```

Do not test this. **Make it hold by construction** by factoring both through
one interpreter parameterised over the monad:

```haskell
interp :: Monad m
       => (Request -> m (Either Refusal Response))
       -> (Call -> m Obs)
       -> Cofree HarnessF Ctx -> m Outcome

run   env = interp (oracle env) (world env)
probe h   = interp (pure . guessOracle h) (pure . guessWorld h)
            -- in a fuel-limited Writer [Ev]
```

`probe` also needs to emit events and respect a depth bound, both of which are
monadic effects, not extra cases. This is the single highest-payoff change in
the review: it removes a duplicated interpretation, makes the agreement law
free, and satisfies §15's closed-alphabet discipline in one place instead of
two. `[design]` → **D9**

### 16.2 The ordering trap, applied to the compaction law

The guide's flagged trap is that if order matters, a combinator cannot be
commutative, and the fix is to observe into a multiset rather than a list. This
lands directly on `respectsBehaviour`, which compares `[Ev]` with `==`.

That is too strong. Tool calls within a single assistant message are
**unordered** — pi executes them in parallel by default — so a compaction that
permutes independent calls within a turn would register as a violation while
being behaviourally identical. The trace is a *list of multisets*, one multiset
per turn, not a list of events.

It is also too coarse in the other direction: a boolean tells you nothing about
*how* a compaction diverged, and E1 explicitly needs a classification.

The ADD move is to replace one over-strong observation with a product of
several coarser ones, each with its own algebra:

| observation | algebra | divergence means |
|---|---|---|
| halt outcome | `Last Outcome` | the task ends differently |
| irreversible actions | multiset of tool names | side effects gained or lost |
| oracle call count | `Sum Int` | cost changed |
| per-turn call sets | list of multisets | ordering-insensitive behaviour |

Each component that differs *names a divergence kind*, so E1's classification
falls out of the observation's structure rather than being bolted on.
`[design]` → **D10**

### 16.3 `Risk` is a monoid, so D1 is easier than §10 claims

Correction to §10. Every field of `Risk` already carries a monoid:

```haskell
stepsAhead   :: Int      -- Sum
terminates   :: Bool     -- Any
irreversible :: [String]  -- free monoid (make it a multiset per 16.2)
compactions  :: Int      -- Sum
```

So the `Monoid` instance exists and can be derived generically from the
component monoids off the back of `Generic`. §10's hedge that "the monoid may
not exist" was wrong for the statistic as currently written; it becomes true
again only under D2, when `Risk` becomes a distribution.

The memoisation story also needs correcting, and the correction is a nicer
result. Under a `Hypo`, the branching tree collapses to a **path**, which is a
stream — and `extend` on a stream with a monoidal statistic is exactly a
`scanr` over `tails`. So:

- along the path a run actually traverses, `governed` is a scan and is linear;
- across the whole branching tree it is not, because off-path nodes share no
  suffix.

A run only ever visits one path, so the linear version is enough for the
governance gate, which is the use case. Scope the fix that way and say so.
`[established]` — the collapse is what `probe` already does; the scan
observation follows.

### 16.4 Nothing stops the coalgebra emitting an unafforded call

`step` takes `pending = calls r` straight from the oracle's response with no
check against `afford s`. A model that hallucinates a tool name, or calls
`commit` before any write has happened, produces a `Perform` for a call the
harness never offered. This is not hypothetical; it is the failure mode a local
Qwen will exhibit within minutes (§12), and it is the same territory as D3.

Two routes, and the guide is explicit about which to take first. The type-level
version indexes `Call` by the available tool set, which is heavy. The
term-level version is a smart constructor plus a law:

```haskell
admit :: [ToolSpec] -> Call -> Either String Call
```

and the property: **`probe` never emits `Did c` whose tool is absent from the
`Ctx` at that node.** That is checkable, cheap, and gets most of the safety.
Note this makes the invariant part of the *law suite* rather than the type, so
it must actually be tested or it does not exist. `[design]` → **D12**

### 16.5 `compact` is not idempotent at the boundary

`compact s = s { transcript = take 2 ts ++ [User []] }`. For `|ts| >= 2` this
happens to be idempotent; for `|ts| < 2` it grows the transcript on each
application. ADD's by-fiat normal form applies: enforce `compact . compact ==
compact` in a smart constructor, and while you are there forbid `Summary` turns
from nesting. Cheap, and it is the kind of boundary bug that will otherwise
surface as an infinite compaction loop under memory pressure. `[established]`
→ **D11**

### 16.6 `project` is prefix-stable, and that is what makes prompt caching sound

Worth writing down as a law to protect, because it is invisible until someone
breaks it:

```
project (t : ts)  ==  project ts <> renderLine t
```

Appending a new turn appends to the *end* of the prompt and leaves the prefix
untouched. That is exactly the condition under which provider prompt-prefix
caching is valid, and a well-meaning change — inserting a running token count
into the header, say, or re-sorting turns — would silently destroy cache hit
rates with no other symptom.

The law is conditional: it holds in `Working` mode and fails across a
compaction, deliberately. Which names a real cost the brief did not previously
state. **Compaction does not just lose information; it invalidates the entire
prompt cache.** That should go into E1's cost model. `[established]`

### 16.7 Generate `S` only through public transitions

The ADD rule is that `Arbitrary` instances go through public combinators, never
raw constructors, with an incomplete-match guard so a new constructor breaks
the build. Here that means: **never generate an `S` by filling in the record.**
Generate a sequence of oracle and world responses, run the harness, and take
the reachable states it produces.

This is not pedantry. The `sampleS` I hand-wrote in `reference/Run.hs` gave a
false `True` from `respectsBehaviour`, and hand-written states can be
unreachable outright — testing compaction on a state the coalgebra can never
produce is measuring nothing. Fold this into T4. `[established]`

### 16.8 What the guide offers that this project should decline

Recorded so the decisions are not relitigated.

- **GADT-indexed alphabet (A2).** The result type of each action is already
  carried by the continuation's argument type; that *is* the polynomial
  structure. A GADT would restate it with worse error messages.
- **Phantom-tagged `S (m :: Mode)` (A1 lifecycle).** Tempting for the
  `Working`/`Summarising` transitions, but `step` would have to return an
  existential because the mode is not known statically at a tree node. The
  guide's own advice — prototype one invariant, existential machinery carries
  `unsafeCoerce` internals — argues against. The mode bug it prevents is narrow.
- **Indexed monad for a balance invariant (A3).** No conservation law here.
  Token budget is monotone-decreasing, not balanced.
- **Promoted units (A4).** Only one dimension in play, tokens. A smart
  constructor is sufficient.
- **First-class families (A5).** No.
- **QuickSpec.** Possibly worth one run over `compact`, `step`, and `project`
  to discover rewrites, but the guide's caveats apply: slow, noisy, needs
  curation. Not a first move.

### 16.9 Summary of what changes

Cheap wins, in order: unify the interpreter (16.1), fix the compaction
observation (16.2), derive `Risk`'s `Monoid` (16.3), smart-constructor the
affordance check (16.4), make `compact` idempotent by fiat (16.5). Then the
generator discipline (16.7) before any law test is trusted.

The three laws worth writing before the code that satisfies them:

```
run (liftHypo h) w   ≡  outcomeOf (probe h ∞ w)          -- 16.1, free by construction
observe (compact s)  ≡  observe s                        -- 16.2, expected to fail, measure the rate
project (t : ts)     ≡  project ts <> renderLine t       -- 16.6, protects prompt caching
```
