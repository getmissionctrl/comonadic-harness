# Phase 2 — the recipe morphism `[unbuilt]`

> Everything in this document is `[unbuilt]`. No code has been written for any
> of it. It names a seam and an open question so that phase 2 starts from a
> stated shape rather than a blank page. Nothing here is a commitment.

## The claim `[speculative]`

`vf-haskell` already has a free monad describing what a value-flow process
*does*: `Contract.DSL.RecipeF` (with `Recipe = Free RecipeF`). This project has
a cofree coalgebra describing what an agent *does*: `HarnessF` unfolded into
`Cofree HarnessF Ctx`. Phase 2 is the morphism between them — compiling a
`Recipe` (a plan) into a `HarnessF`-program (an executable agent), so that the
parts of a value-flow model that need judgement or generation are handed to the
LLM through the *same three constructors* the rest of this project is built on.

The pairing is not incidental. A free monad is the initial algebra of "programs
that ask"; a cofree comonad is the terminal coalgebra of "processes that
answer". A recipe is written; a harness is run. Phase 2 asks whether the first
compiles into the second without either side growing a special case.

## The seam `[unbuilt]`

The two types to sit either side of the morphism:

- **Source:** `Contract.DSL.RecipeF next` in `vf-haskell` — a free-monad functor
  whose constructors are the value-flow verbs: `WorkF` (effort a role expends),
  `ConsumeF` / `UseF` / `ProduceF` (resource flows), `ProcessF` (a named
  sub-recipe), and the structural combinators `BothF`, `BranchF`,
  `AlternativesF`. `Recipe a` is `Free RecipeF a`. Its knowledge-layer companion
  `VF.Types.Recipe` (`ProcessSpecification`, `RecipeProcess`, `RecipeFlow`)
  supplies the templates a recipe instantiates.
- **Target:** `Harness.Alphabet.HarnessF` — `Render` / `Perform` / `Halt`,
  unfolded by `Harness.Coalgebra.step` from a state `S`.

The morphism is a pass `compile :: Recipe a -> S`, seeding a coalgebra whose
`step` walks the recipe. It is a fold of the free structure into the harness
state, dual to the `unfold` that produces the tree — *fold-then-unfold*, the
same shape `Harness.Evolve` already uses for evolution (invariant 4: the
recipe does not become a `HarnessF` constructor).

### Which recipe steps land where

- The **deterministic** verbs — `ConsumeF`, `ProduceF`, `UseF`, and the
  resource accounting behind them — are bookkeeping. They belong in `S` and in
  `step`, never in the alphabet (invariant 2: they are shape, not annotation,
  and they choose successors deterministically).
- The **judgement-bearing** verbs — a `WorkF` whose effort is "decide", a
  `ProcessF` whose body is under-specified, an `AlternativesF` whose choice is
  not forced by the accounting — are the positions where control leaves the
  harness. Each becomes a `Render` (ask the oracle) or a `Perform` (act on the
  world) whose *direction* is what the harness does not control. This is exactly
  the position/direction split of §1: the recipe fixes the positions, the model
  supplies the directions.

## Value-flow models as executable Petri nets `[speculative]`

A value-flow model is already close to a Petri net: processes are transitions,
resources and their `RecipeFlow`s are places, quantities are token counts. Phase
2's executable reading is that firing a transition either (a) fires
deterministically inside `step` when the inputs and the recipe fully determine
the output, or (b) suspends into a `Render` / `Perform` when a *part* of the
transition needs the LLM — a description written, a choice made, a value
appraised — and resumes when the direction comes back. The net is the shape;
the suspended parts are where the annotation-carrying tree meets a live model.

## The open question — human-in-the-loop `[unbuilt]`

Where does the human live?

Not in the alphabet. A fourth `HarnessF` constructor for "ask a person" would
break invariant 1 (the alphabet is closed) for the same reason `Evolve` was
kept out of it: the alphabet enumerates what the harness *does*, and asking a
person is not a new kind of doing — it is a different *answerer* for the two
constructors that already ask (`Render`) and act (`Perform`).

So a human is a **fourth interpretation of the same three constructors**, beside
the two this project already ships:

| interpreter | monad | oracle / world resolved by |
|---|---|---|
| `Harness.Run.run` | `IO` | the live provider and the real world |
| `Harness.Probe.probe` | `Writer [Ev]` | a pure `Hypo` |
| *(phase 2)* consult | some `m` | **a person**, asynchronously |

All three factor through the one `Harness.Interp.interp` (§16.1), so a
human-in-the-loop interpreter inherits the agreement law for free: what a person
drives and what `probe` forecasts are the same walk of the same tree.

The genuinely open part is **durability**. A human answer does not arrive within
one `IO` action; the tree must be checkpointed at a `Render` / `Perform` node,
persisted, and resumed when the person replies — without serialising the
`Cofree` (invariant 3: it is a denotation, not a runtime representation). The
resumable thing is `S` plus the position in the recipe, from which the tree is
re-`unfold`ed. Naming that checkpoint type, and proving resume is a coalgebra
homomorphism (the resumed run is bisimilar to the un-suspended one), is the
first concrete piece of phase-2 work — and the first place the "durable" in
"durable polynomial coalgebra" would have to be earned rather than asserted.
