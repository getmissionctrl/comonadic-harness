# References

Grouped by what they are actually for. Annotations say why each matters to
this project, not what it says in the abstract.

---

## The originating idea

**Phil Freeman, *The Future Is Comonadic*.**
<https://functorial.com/the-future-is-comonadic/main.pdf>

A UI specification is a comonad `w` of reachable next states; the allowed
transitions are the `Co w` monad. Gives the expressiveness ladder used in
§3 of the brief (Store, Moore, Cofree), the `Sum` and `Day` composition
theorems, and the `Co (Cofree f) ≅ Free f` correspondence. Predates the
polynomial-functor framing and does not reach mode-dependence.

**Edward Kmett, "Monads from Comonads" (2011).**
<http://comonad.com/reader/2011/monads-from-comonads/>

The `Co w` construction Freeman builds on.

**Dave Laing, "Cofree meets Free" series.**
<http://dlaing.org/cofun/>

The canonical treatment of free monad as DSL, cofree comonad as interpreter,
and the `Pairing` class that makes them run against each other. Closest
existing thing to the driver side described in §13.

---

## Coalgebra and bisimulation

**J. J. M. M. Rutten, "Universal coalgebra: a theory of systems."**
*Theoretical Computer Science* 249(1), 2000.
<https://doi.org/10.1016/S0304-3975(00)00056-6>

The source for the compaction law in §6. Coalgebra homomorphisms, final
coalgebras, and bisimulation as the canonical behavioural equivalence. If you
read one thing from this list, read this.

**Josée Desharnais, Vineet Gupta, Radha Jagadeesan, Prakash Panangaden,
"Metrics for labelled Markov processes."** *TCS* 318(3), 2004.
<https://doi.org/10.1016/j.tcs.2003.09.013>

**Franck van Breugel and James Worrell, "Towards quantitative verification of
probabilistic transition systems."** ICALP 2001.
<https://doi.org/10.1007/3-540-48224-5_34>

Behavioural pseudometrics: the quantitative generalisation of bisimulation.
This is the framework for "how badly did this compaction hurt" rather than a
boolean. Marked `[speculative]` in the brief because applying it here is
untested.

**Tarmo Uustalu and Varmo Vene, "Comonadic Notions of Computation."**
*ENTCS* 203(5), 2008.
<https://doi.org/10.1016/j.entcs.2008.05.029>

**Tarmo Uustalu and Varmo Vene, "The Essence of Dataflow Programming."**
APLAS 2005 / LNCS 4164.

Comonads as context-dependent evaluation. The general theory behind "annotate
every position with a function of its neighbourhood", which is what `governed`
does in §5.

**Danel Ahman, James Chapman, Tarmo Uustalu, "When Is a Container a Comonad?"**
FoSSaCS 2012.
<https://doi.org/10.1007/978-3-642-28729-9_5>

Directly adjacent to Ghani's containers work. Relevant if you ever want to
characterise which `HarnessF` shapes admit the structure you want.

---

## Polynomial functors and mode-dependence

**David I. Spivak and Nelson Niu, *Polynomial Functors: A Mathematical Theory
of Interaction*.**
<https://topos.site/poly-book.pdf>

The right home for mode-dependent affordances (§3). A harness is a lens
`Sy^S → p` where `p`'s positions are rendered requests and directions are legal
responses. Comonoids in `(Poly, y, ◁)` are exactly small categories, which is
what a harness with composable transitions is. `Cofree f` fixes the same `f` at
every node and therefore cannot express state-dependent tool availability at
the type level; the reference code works around this with a fold, which is
correct but untyped.

**David Jaz Myers, *Categorical Systems Theory*.**
<http://davidjaz.com/Papers/DynamicalBook.pdf>

Behaviour, composition, and doubly indexed categories. The systems-theoretic
version of the same material.

---

## The two harnesses that were read

**`earendil-works/pi`** — <https://github.com/earendil-works/pi>

TypeScript. Read `packages/agent/src/agent-loop.ts`,
`packages/agent/src/harness/agent-harness.ts`,
`packages/agent/src/harness/reducer.ts`, and
`packages/coding-agent/src/core/agent-session.ts`. See §2 for the specific
structures worth stealing: `peekAction`/`executeAction`, `ActionInfo`,
`reduceLaneState`, `SuspendedOperation`, `replay: "never" | "safe"`.

**`lucasdicioccio/agents-exe`** — <https://github.com/lucasdicioccio/agents-exe>

Haskell. Read `src/System/Agents/Session/{Base,Step,Loop}.hs` — about 660 lines
and that is the whole harness. `Action r` with `Evolve`, `Agent r` with `step`,
and the comment explaining why forking was rejected. Also
`src/System/Agents/Combinators/ProgressiveDisclosure.hs` for the affordance
fold done through an `IORef`, and `src/System/Agents/Session/Signals.hs` for
stagnation detection over the past.

Neither mentions comonads. The `Contravariant` in agents-exe is `Prod.Tracer`
logging, not structure.

---

## Haskell libraries

- `free` — <https://hackage.haskell.org/package/free>
  `Control.Comonad.Cofree` (`unfold`, `coiter`), `Control.Monad.Free`.
- `comonad` — <https://hackage.haskell.org/package/comonad>
  `Comonad`, `ComonadApply`, `Env`, `Store`, `Traced`.
- `optics-core` — <https://hackage.haskell.org/package/optics-core>
  `Optics.Generic` gives `gfield`, `gafield`, `gconstructor`, `gplate` off the
  back of `Generic`. No Template Haskell, so no `optics-th` in this project.
- `kan-extensions` — <https://hackage.haskell.org/package/kan-extensions>
  `Data.Functor.Day`, only if §13 is ever built.

---

## Ollama

- API reference — <https://github.com/ollama/ollama/blob/main/docs/api.md>
- Tool calling — <https://ollama.com/blog/tool-support>
- OpenAI compatibility — <https://ollama.com/blog/openai-compatibility>

Verify everything in §12 against the installed version rather than these docs;
`num_ctx` defaults and overflow behaviour have both changed across releases.

---

## Background the design leans on but does not cite in code

**John Boyd, "Destruction and Creation" (1976).**

The inner/outer loop split in §7. Inner loop is inference within a model; outer
loop is inference about the model. Boyd's destructive deduction is
fold-then-reunfold.

**Bertrand Meyer, on the probable/provable split.**

LLM reasoning on the probable side, typed deterministic machinery on the
provable side. The `Env`/harness boundary in this design is exactly that line,
and the reason `run` must never read the annotation.

---

## Design method

**Sandy Maguire, *Algebra-Driven Design*.**

The observations-first loop used in §16: decide the functions *out* of the
algebra, add constructors, write laws relating each new constructor to the
existing ones, reason equationally, then derive and property-test. Sources of
the ordering trap (§16.2), by-fiat normal forms (§16.5), and the
public-combinator generator rule (§16.7).

**Sandy Maguire, *Thinking with Types: Type-Level Programming in Haskell*.**

Consulted for §16.8, mostly to record what this project should *decline*.
The relevant chapters are the lifecycle-phantom pattern, GADT indexing,
indexed monads, and the caution that type-family safety must ship with
`TypeError` messages or the typed API gets abandoned.

A distilled, vf-haskell-oriented reading of both is what §16 was written
against; keep it to hand when working T3 and T4.
