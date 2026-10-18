# What to adopt from *Learn Harness Engineering*

A review of [walkinglabs/learn-harness-engineering](https://github.com/walkinglabs/learn-harness-engineering)
(14 lectures, 8 projects, the `harness-creator` skill, and four "frontier
harness" breakdowns: Claude Code, Codex, Pi, DeepSeek), read against this
repository at `f57ee1e`. The question asked is narrow: which of its mechanisms
would make this harness better without breaking an invariant in `CLAUDE.md`?

Provenance tags follow the repo convention. Claims about this codebase are
`[established]` only where a file is cited; everything proposed is `[design]`
or `[unbuilt]`.

---

## 1. Verdict

The course is a good practitioner synthesis, but it is written for harnesses
whose state is markdown files and whose rules are prompt text. Much of what it
teaches as discipline (scope control, affordance limits, observability, a
hostile-model posture) this repo already carries as types and laws. `[design]`

Six things are worth adopting. All six fit inside the five invariants: the
alphabet stays closed, and each addition is a quotient, an `Env` decorator, or
a field of `S`, testable against the laws already present.

| # | Adopt | Course source | Lands in | Cost |
|---|---|---|---|---|
| A1 | Harness-owned termination (`Verifying` mode) | L09, L10, L13 | `S`, `step`, `request` | medium |
| A2 | Compaction as a staged funnel | Claude Code breakdown, context pattern | `Compaction`, `State` | medium |
| A3 | Fail-closed registry, per-call effect classes | tool-registry pattern, gotchas #5 #13 | `ToolSpec`, `afford`, `Risk` | medium |
| A4 | Layered policy, deny-dominant | tool-registry + memory patterns | new pure `Policy` module | medium |
| A5 | Actionable error observations | L09 (Codex practice) | `admit` | low |
| A6 | Preflight / clean-state checks | L06, L12, lifecycle pattern | before first `step` | low |

---

## 2. A1 — the harness owns "done"

**The gap.** `step` halts with `Done` as soon as the newest turn is an
`Assistant` response with no calls (`src/Harness/Coalgebra.hs`, the
`(Working, Assistant r : _) | null (calls r)` case). `[established]` The model
therefore decides when the work is finished. That is exactly the failure mode
L09 is built around: agents are systematically overconfident about completion,
and self-evaluation skews positive.

**The move.** Add a `Verifying` mode to `Mode`. When the model stops calling
tools in `Working`, `step` does not halt; it transitions to `Verifying` and
emits a `Perform` of a check that **the harness** chooses (build, test suite,
an end-to-end probe), taken from `S`, not from the model. `[design]`

- A passing observation yields `Halt (Done …)`.
- A failing observation is recorded as a `User` turn and the mode returns to
  `Working`, so the model sees the failure and continues.
- Budget still bounds the loop, so liveness is unchanged (`spend` keeps its
  minimum of 1).

This needs no new constructor. It is the same shape as `Summarising`: a mode
that changes what `request` and `afford` produce, read by the existing `case`
in `step`. Invariant 1 holds.

**Maker–checker without a new agent.** The course's evaluator separation (L09,
L13) maps onto a different `project`, not a second harness: a checker `Render`
whose request carries the artefacts and the acceptance criteria but not the
maker's reasoning. Its context is fresh by construction, which is the property
the course is reaching for. `[design]`

**Experiment (E5, proposed).** Small local model, fixed task corpus. Treatment:
`Verifying` on. Baseline: current behaviour. Metrics: completion rate, and the
rate of *false* `Done` (halts the external check would have failed). Predicted
result: completion rises and false `Done` falls sharply, at a token cost. If
false `Done` does not fall, the check set is too weak, which is a finding about
the checks, not the mode. `[speculative]`

---

## 3. A2 — compaction as a funnel

**The gap.** `summarising` collapses the whole transcript to one
`[Summary (say r)]` turn. `[established]` That discards the original task
statement and the most recent turns along with the middle, and it pays the
highest information loss first.

**The course's evidence.** The Claude Code breakdown (citing VILA Lab's
source-level analysis) describes a multi-stage funnel: lossless pruning
(redundant tool results), then structured distillation, then a lossy LLM
summary, with circuit breakers against over-compaction. The context pattern
adds: preserve recent turns verbatim and label the snapshot with where it was
cut.

**The move.** Express compaction as a composition of quotients ordered by how
much each loses: `[design]`

1. **Lossless.** Drop redundant or superseded tool results; replace large
   observations by references. Much of this already exists in `Harness.Ref`
   (`absorb`, `jsonpath`, `deref`). `[established]`
2. **Pinned.** Keep the seeded task turn and the last *k* turns verbatim.
3. **Lossy.** Summarise only the middle, through the existing `Summarising`
   `Render`, so the alphabet does not grow.
4. **Breaker.** If a stage fails to bring the request under the window, try the
   next; if the lossy stage itself overflows, keep the current behaviour
   (zero the budget, halt `Exhausted`).

**Why this suits the repo better than it suits the course.** The course can
only describe the funnel. Here each stage is an `S -> S` that can be run
through `respectsBehaviour`, so E1 can report the defect rate **per stage**
against the no-op baseline. That turns "compaction is lossy" into a ranking of
which loss actually changes behaviour. `[design]`

---

## 4. A3 — a fail-closed registry with per-call effect classes

**The gap.** Safety is keyed on tool *names*: `afford` withholds `commit` until
a successful `write`, and `Risk.irreversible` names `"write"` and `"commit"`.
`[established]` That works only while no universal tool is afforded. `bash` is
correctly excluded from `allTools` and refused by `sandboxAct`
(`src/Provider/Tools.hs`). `[established]` But the moment it returns,
`bash "git commit …"` bypasses the commit gate.

**The course's principles.** Fail closed: tools are non-read-only and
non-concurrent unless declared otherwise (gotcha #13: the dangerous default is
"allow"). Classification is per **call**, not per tool (gotcha #5).

**The move.** `[design]`

- Extend `ToolSpec` with a classifier `Call -> Effect`, where
  `Effect = ReadOnly | Reversible | Irreversible`, defaulting to
  `Irreversible`.
- Reuse the existing `ReplaySafety` vocabulary in `Harness.Alphabet`, which is
  already declared as groundwork for D4 but consumed by nothing. `[established]`
  The classifier returns both.
- Let `afford` and `admit` gate on `Effect` rather than on names, and derive
  `Risk.irreversible` from the classifier rather than from a hard-coded list.
- `bash` can then come back with an argument-aware classifier: `cat`/`ls` are
  `ReadOnly`; `git commit` is `Irreversible` and subject to the same
  precondition as `commit`.

This also gives D4 the replay annotation it needs: a resume re-performs only
`ReplaySafe` calls.

---

## 5. A4 — layered policy, but deny-dominant

**What the course says.** Permissions compose across layers (org → user →
project → local → session), and for instruction memory the most local layer
wins.

**Where to diverge.** Local-wins is right for *preferences* and wrong for
*authority*. A local override must not be able to loosen an organisation's
ban. For the independent-controls property (an organisation decides, outside
the model, what a model may access and do), the combination must be: `[design]`

- any `Deny` at any layer wins;
- the org layer is a ceiling no lower layer can raise;
- lower layers may only narrow.

**Keep it pure.** The course's evaluator is stateful (it tracks denials and
switches modes as a side effect, gotcha #6). Here that would break the
`run`/`probe` agreement, because `probe` could not reproduce the evaluator's
hidden state. So: `policy :: PolicyStack -> S -> Call -> Verdict`, with denial
history held in `S` if it is needed at all. `probe` can then forecast policy
denials exactly. `[design]`

This is also the route to the affordance policy becoming *data* an operator
owns, rather than a Haskell function only the developer can change.

---

## 6. A5 — actionable error observations

**The gap.** `admit` repairs an unafforded call into
`error: tool not afforded: <name>`. `[established]`

**The move (from the course's Codex material).** Error text written for an
agent should say how to fix the error. Include the currently afforded tool
names and, for argument failures, the expected schema from `ToolSpec`.
`[design]`

**Why it is worth measuring.** The local Qwen model (§12 of `BRIEF.md`) is the
ideal subject because it mis-calls tools often. Measure tool-call repair rate
(the fraction of rejected calls followed by a valid call on the next turn)
with the current and the enriched observations, on the HostileSpec-style
corpus. Cheap to build, and the result will be clear either way. `[speculative]`

---

## 7. A6 — preflight and clean state

**The course.** L06: initialisation is its own phase; verify the environment
before the agent works. L12: every session leaves a clean state for the next.

**The move.** Before the first `step`, check that every tool and model the run
will need is actually supplied by `Env`, and halt with a distinct outcome if
not. This is the same idea as pi's `SuspendedOperation.missing: { tools,
models }` (`BRIEF.md` §2): resume can fail because the environment no longer
supplies capabilities the log refers to. Combined with the D4 log, this gives
a clean, checkable handoff. `[design]` `[unbuilt]`

---

## 8. Already ahead of the course

| Course mechanism | Here | Status |
|---|---|---|
| Truncation recovery pointers ("call X for full output") | pass-by-reference `Obs`, `jsonpath`/`deref` | `[established]` |
| Append-only, replayable session history (`history.jsonl`) | stronger available: log only the **directions** (oracle responses, world observations); with seed `S`, re-unfolding reproduces the run exactly | `[design]` — this is D4 |
| Hooks (`PreToolUse`, `PostToolUse`, `Stop`) | `project` and `Env` decorators (§9); `traceEnv` already uses this seam for AG-UI | `[established]` |
| "Isolation must be enforced at call time, not by hiding tools from the prompt" | `admit` gates every pending call against `afford` | `[established]` |
| Hostile-model posture | HostileSpec: 150 seeds, zero crashes, every run reaches `Done`/`Exhausted`/`Failed` | `[established]` |
| Graph engineering (L14) | `Sum` for modes, `Day` for parallel components (§13), the Recipe → `HarnessF` morphism (`docs/phase-2-recipe-morphism.md`) | `[unbuilt]`, but stated |

**Worth stealing from L14 as test cases.** Its three structural failures of
loops-at-scale (Goodhart, where the loop optimises a metric that drifts from
the goal; blindness upward, where the loop never questions its goal; and
conflict between independent loops) are good adversarial scenarios for phase
2. Its "anchor" (pin loops to real outcomes) corresponds to vf-haskell's
resource accounting. `[speculative]`

---

## 9. Skip

- **Markdown progress files and `feature_list.json` as state.** They exist
  because those harnesses cannot own typed state. Here, goals belong in `S`,
  ideally compiled from a recipe.
- **Stateful permission evaluators.** They break the `run`/`probe` agreement
  (see A4).
- **Fork / swarm delegation patterns.** Not until something forces them (§13).

---

## 10. Calibration on the course's evidence

The course is careful to call its numerical cutoffs teaching defaults. Its
headline comparison (a $9, 20-minute single-agent run against a $200, 6-hour
planner–generator–evaluator run, from Anthropic's long-running-apps post) uses
different budgets and runtimes, so it is a case comparison, not an ablation of
any one component. The course notes this itself. Treat it as motivation for
A1, not as a measured effect size. `[established]` — stated in L09.

---

## 11. Hygiene found while reviewing

- **`README.md` contradicts the code on `bash`.** The README says `bash` runs
  in the sandbox with a 10s timeout. `allTools` excludes it and `sandboxAct`
  refuses it unless `trustedShellWorld` is chosen. `[established]` Fix the
  README before anyone reads it as a containment claim.

---

## 12. Suggested order

1. **A5**: smallest; produces a measurable result on the local model this week.
2. **A1**: closes the largest real gap; experiment E5.
3. **A3**: prerequisite for both `bash` and D4; reuses `ReplaySafety`.
4. **D4** (direction log + replay law): now cheap given A3; the audit and
   replay story depends on it.
5. **A2**: becomes the E1 bake-off, per stage.
6. **A4, A6**: when an operator other than the developer needs to own policy.

Each step is additive to `TASKS.md` and should get its law before its code
(`CLAUDE.md`, evidence discipline).
