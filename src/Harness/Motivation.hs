-- | Why the harness is a durable polynomial coalgebra over a closed alphabet,
-- derived from a single claim in @BRIEF.md@ (§§1, 3, 5, 6). Three small
-- illustrations ('exampleStep', 'exampleRun', 'irreversible') are exported and
-- compiled under the same strict warnings as the rest of the library, so the
-- argument cannot drift from code that builds. A statement proved by code here
-- is tagged @[established]@; a defensible-but-unforced choice is @[design]@.
module Harness.Motivation
  ( -- * The claim
    -- $claim

    -- * Nondeterminism lives in the directions
    -- $directions
    exampleStep

    -- * The minimal definition
    -- $minimal

    -- * What the comonad buys: counterfactual annotation
    -- $governed

    -- * Compaction and its correctness condition
    -- $compaction
  , irreversible

    -- * Where the LLM lives, and why the alphabet does not grow
    -- $closed
  , exampleRun
  ) where

import Harness.Alphabet
import Harness.State

{- $claim
An agentic harness is a __durable polynomial coalgebra over a closed action
alphabet, equipped with three lossy quotients and one unreliable oracle
boundary__ (§1). Everything below unpacks that sentence into types that already
exist in this library, plus three tiny illustrations that compile.

@Cofree 'HarnessF' 'Ctx'@ is the /denotation/ of the coalgebra — the
lazily-unfolded tree of every reachable state — not its runtime representation.
You implement the coalgebra @'S' -> 'HarnessF' 'S'@ and reason with the tree.
-}

{- $directions
The alphabet is 'HarnessF', and the load-bearing decision is where the
nondeterminism sits. A 'Render' position is a fixed 'Request'; its /direction/
is a function @Either 'Refusal' 'Response' -> x@. The harness always knows what
it does next (the position). What it does not know is what comes back (the
direction). @[established]@

That shaping is what makes @duplicate@ on the unfolded tree pure and lazy: a
branch is a function of an as-yet-unobserved input, not an effect that must be
run to be seen. The standard objection — \"an agent must run tools to enumerate
its futures\" — dissolves, because the tree branches on unobserved /inputs/, not
on unperformed /effects/ (§1).

The whole coalgebra is 'Harness.Coalgebra.step'; 'exampleStep' is a deliberately
smaller one that shows the same move — a deterministic position ('Render') whose
successor is a pure function of the oracle's reply:

@
'exampleStep' :: 'S' -> 'HarnessF' 'S'
'exampleStep' s = 'Render' ('request' s) reply
  where
    reply (Left _)  = s { 'budget' = 0 }
    reply (Right r) = s { 'transcript' = 'Assistant' r : 'transcript' s }
@
-}

-- | A minimal coalgebra fragment: emit the request, and on reply either halt by
-- spending the budget or record the (unobserved-until-now) response and carry
-- on. The nondeterminism is entirely in the @Either 'Refusal' 'Response'@
-- argument — the position 'Render' is fixed. This is the §1 move in one line.
exampleStep :: S -> HarnessF S
exampleStep s = Render (request s) reply
  where
    reply (Left _)  = s { budget = 0 }
    reply (Right r) = s { transcript = Assistant r : transcript s }

{- $minimal
Section 3 names exactly five things, and each is a value already in scope:

* __State 'S'__ — the transcript and the token budget.

* __Alphabet with a result family__ — 'HarnessF', where each position's
  direction type /is/ the observation type of that action. That per-action
  dependence is what makes the interface polynomial, @p(X) = Σ_σ X^Obs(σ)@, and
  is why a fixed product of handlers cannot type it. @[established]@

* __Coalgebra__ — @step :: 'S' -> 'HarnessF' 'S'@.

* __Three quotients on 'S'__ — 'project' (lossy, what the model sees), @compact@
  (lossy, what the harness keeps), @persist@ (lossless, what survives a crash).
  Only 'project' is exercised here.

* __Oracle boundary__ — an external, flaky, adversarial-in-the-limit
  @'Request' -> m (Either 'Refusal' 'Response')@, explicitly /not/ part of the
  harness. The obligation is to behave for an arbitrary oracle.

That the affordances are mode-dependent — 'afford' is a fold over the
transcript, not a constant — is the polynomial structure made concrete: which
directions are legal depends on the state. 'exampleStep' already used 'request'
to compute that legal request from the state, purely and without an oracle call.
-}

{- $governed
You cannot fold an infinitely-branching tree. You can fold it under a
/hypothesis/ — a pure stand-in for the oracle and the world — which collapses
the branching to a single path (§5). 'Harness.Probe.assess' scores one node that
way; @extend ('Harness.Probe.assess' h n)@ then annotates /every reachable
state/ with a counterfactual assessment of its own future, from a function that
only knows how to score one position. @extract@ recovers the assessment at the
current node, which is the pre-action governance gate.

The forecast is only as good as the hypothesis: in the recorded run it gets the
shape right and the content wrong (@runs\/oracle-output.txt@). The comonad
supplies the plumbing to attach forward-looking assessment cheaply; it does not
supply a model of the oracle. @[established]@
-}

{- $compaction
This is the result the design exists for (§6). Compaction @compact :: 'S' ->
'S'@ should be a __coalgebra homomorphism__:

@
step (compact s)  ==  fmap compact (step s)
@

Equivalently, @s@ and @compact s@ are bisimilar and @unfold@ factors through
@compact@. You cannot check that directly, because @'HarnessF' 'S'@ contains
functions; you check its observable shadow. And the shadow is /sharper/ than the
naive statement: compaction must change the prompt, so the equivalence has to be
on the __action trace__, never on the rendered context. Hence the governing
slogan: /compaction is correct exactly when it is invisible in what the agent
does, not in what it sees./ @[design]@

The one observation that matters most is the multiset of irreversible actions: a
compaction that manufactures or drops a write has changed behaviour, whatever it
did to the prompt. 'irreversible' is that observation as a tiny fold — the same
notion 'Harness.Compaction.respectsBehaviour' checks at scale.

The first sample state ever tried returned \"respects behaviour? @True@\" by
coincidence, because compacted and uncompacted happened to sit on the same side
of the hypothesis threshold. The property is state-dependent; checking it at one
state proves nothing. It wants a /violation rate/ over states generated through
public transitions, not a boolean (§6). @[established]@
-}

-- | The irreversible actions a transcript performed, as a plain list (read it
-- as a multiset). A compaction that changes this has changed behaviour, which
-- is the divergence 'Harness.Compaction.respectsBehaviour' is built to catch.
irreversible :: [Turn] -> [String]
irreversible = concatMap turnWrites
  where
    turnWrites (User rs) = [tool c | (c, _) <- rs, tool c `elem` writers]
    turnWrites _         = []
    writers = ["write", "commit"]

{- $closed
The oracle is one field of the environment, consumed by one line of the
interpreter. Compaction needs a summarisation call, and it goes through the very
same 'Render' constructor: in 'Summarising' mode 'request' supplies a
summarisation prompt and /no tools/. The alphabet stays at three constructors.

'exampleRun' ties the two halves together without any effect: given a pure
reply, 'exampleStep' produces a concrete successor state, so \"position fixed,
direction pure\" is not just prose. Its @case@ is exhaustive over all three
constructors on purpose — the alphabet is closed, and a wildcard would hide the
day a fourth constructor is added (invariant 1). That discipline — one
interpretation per alphabet, no escape hatch — is the whole reason the agreement
between execution and analysis is a law you can state rather than a coincidence
you hope for.
-}

-- | Drive 'exampleStep' one step with a supplied (pure) reply. No oracle, no
-- @IO@: the successor is a function of the reply, exactly as §1 requires.
exampleRun :: S -> Either Refusal Response -> S
exampleRun s r = case exampleStep s of
  Render _ k  -> k r
  Perform _ k -> k (Obs "")   -- unreachable for this fragment; kept total
  Halt _      -> s
