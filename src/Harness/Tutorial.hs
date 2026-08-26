{-# OPTIONS_GHC -fno-warn-unused-imports #-}

-- | How the harness fits together: the closed alphabet ('HarnessF'), the
-- coalgebra ('step', 'harness'), the shape\/annotation split ('view'),
-- execution versus governance ('run' versus 'governed'), and compaction's law
-- ('respectsBehaviour').
module Harness.Tutorial
  ( -- * Introduction
    -- $introduction

    -- * The closed alphabet
    -- $alphabet

    -- * The coalgebra
    -- $coalgebra

    -- * Shape versus annotation
    -- $shape

    -- * Counterfactual governance
    -- $governed

    -- * Compaction and its law
    -- $compaction
  ) where

import Harness.Alphabet
import Harness.State
import Harness.Coalgebra
import Harness.Interp
import Harness.Run
import Harness.Probe
import Harness.Compaction

{- $introduction
An agent, here, is not a loop with side effects. It is a /coalgebra/: a pure
function @'S' -> 'HarnessF' 'S'@ that, given the current state, says what the
agent does next and how each possible reply from the world continues it. The
loop that actually talks to a language model and a shell is a separate thing — an
/interpreter/ ('interp') that walks the shape the coalgebra describes.

That separation is the whole point. The control flow of the agent is a value you
can inspect, fold, and reason about before any I\/O happens; execution ('run')
and analysis ('probe', 'governed') are two interpreters over the /same/ shape,
so anything you prove about one transfers to the other.

Three ideas carry the rest of the tutorial:

* the action alphabet 'HarnessF' is /closed/ — three constructors, no escape
  hatch;

* the tree carries an annotation ('Ctx') that execution is forbidden to read —
  \"execution consumes the shape; analysis consumes the annotation\";

* compaction is a coalgebra homomorphism, and there is a law ('respectsBehaviour')
  that says so in checkable terms.
-}

{- $alphabet
Everything the harness can do is one of three constructors of 'HarnessF':

@
data 'HarnessF' x
  = 'Render' 'Request' (Either 'Refusal' 'Response' -> x)
  | 'Perform' 'Call' ('Obs' -> x)
  | 'Halt' 'Outcome'
@

'Render' asks the oracle (the language model): it carries the 'Request' the
model sees and a continuation that consumes whatever comes back — either a
'Refusal' or a 'Response'. 'Perform' runs a tool 'Call' against the world and
continues with the 'Obs' it produces. 'Halt' stops, carrying an 'Outcome'.

The positions ('Request', 'Call', 'Outcome') are what the harness /does/ and are
fully determined; the directions (the @'Either' 'Refusal' 'Response' -> x@ and
@'Obs' -> x@ functions) are what it does /not/ control. All nondeterminism lives
in the directions. That is what makes 'HarnessF' a polynomial functor and the
unfolded tree lazy.

The alphabet is /closed/: 'Refusal' is only 'Overflow' or @'Malformed' msg@ —
transient failures (429s, socket timeouts) never appear here — and 'Outcome' is
'Done', 'Exhausted', or 'Stuck'. Adding a fourth 'HarnessF' constructor without
a matching case in 'interp' makes @-Wincomplete-patterns@ fail the build. There
is deliberately no wildcard to absorb one.
-}

{- $coalgebra
The coalgebra is the single function 'step':

@
'step' :: 'S' -> 'HarnessF' 'S'
@

It is deterministic: given a state 'S' it always knows what it does next. What
it cannot know is what comes /back/, which is exactly why the successor is a
function of the oracle\/world result rather than a plain state. Read 'step' as a
state transition: out of budget ('budget') it 'Halt's 'Exhausted'; with a 'Call'
'pending' it 'Perform's it; otherwise it 'Render's the current 'request'.

The reply-handling lives in two continuations. 'working' is the 'Working'-mode
successor: an 'Overflow' refusal flips 'mode' to 'Summarising' (a state
transition is the only correct response to overflow, and the coalgebra is the
only thing that can make one); a good 'Response' appends an 'Assistant' turn and
spends its 'Usage'. 'summarising' is the other continuation: on success it
collapses the 'transcript' to a single 'Summary' and returns to 'Working'.

To get a tree, /unfold/ the coalgebra with 'harness':

@
'harness' :: 'S' -> Cofree 'HarnessF' 'Ctx'
'harness' = unfold (\\s -> ('view' s, 'step' s))
@

@'harness' s0@ is the entire branching future of the agent from @s0@, as a
@Cofree 'HarnessF' 'Ctx'@. It is a /denotation/, not a runtime structure: the
implementation carries 'S' and the coalgebra, and never serialises or caches the
tree.

>>> :type harness
harness :: S -> Cofree HarnessF Ctx
-}

{- $shape
Each node of @'harness' s@ is annotated. The unfold pairs @'step' s@ (the shape,
i.e. which 'HarnessF' constructor and its continuation) with @'view' s@ (the
annotation):

@
'view' :: 'S' -> 'Ctx'
'view' s = 'Ctx' ('request' s) ('budget' s) ('mode' s)
@

'Ctx' is what analysis reads: the 'Request' that /would/ be sent, the remaining
budget, the current 'Mode'. The rule is absolute — execution consumes the shape,
analysis consumes the annotation. 'run' never looks at 'Ctx' to choose a
successor; if a field of 'Ctx' ever started influencing execution it would
belong in 'S' and in 'step' instead.

You can see the discipline in 'interp' itself: reading @'ctxMode'@ from the
annotation only /labels/ an emitted 'Ev' ('Asked'); the successor it then walks
is always @k result@, a function of the reply, never of the annotation.

The 'Request' inside 'Ctx' is itself a lossy quotient of the state. 'project'
renders the 'transcript' to a 'Prompt'; 'afford' folds it to the mode-dependent
tool set (@commit@ is only offered once a @write@ has happened); 'request' glues
the two, and adds a summarisation instruction with /no/ tools in 'Summarising'
mode — which is how compaction reuses the one 'Render' constructor.

>>> :type view
view :: S -> Ctx
-}

{- $governed
Because the tree branches on things you do not control, you cannot simply fold
it. But you can fold it under a 'Hypo' — a pure stand-in for the oracle and the
world:

@
data 'Hypo' = 'Hypo'
  { 'guessOracle' :: 'Request' -> Either 'Refusal' 'Response'
  , 'guessWorld'  :: 'Call' -> 'Obs'
  }
@

Under a 'Hypo' the branching collapses to a single path. 'probe' walks that path
to a bounded depth and returns the event trace ('Ev' list); 'liftHypo' turns the
same 'Hypo' into a pure 'Env' — so @'run' ('liftHypo' h)@ and
@'outcomeOf' ('probe' h n _)@ can be checked to agree.

The forecasting story is 'assess' and 'governed'. 'assess' summarises a node's
own future as a 'Risk' (steps ahead, whether it 'terminates', which
'irreversible' tools it touches, how many 'compactions' it triggers). 'governed'
then annotates /every reachable node/ with that forecast, using the comonadic
'Control.Comonad.extend':

@
'governed' :: 'Hypo' -> Int -> Cofree 'HarnessF' 'Ctx' -> Cofree 'HarnessF' 'Risk'
'governed' h n = extend ('assess' h n)
@

The point of 'Control.Comonad.extend' is that it re-annotates each node with a function of that
node's /whole sub-tree/, not just its label — so @extract ('governed' h 32 w)@ is
a pre-action gate computed from the current node's entire forecast future. Both
'run' and 'probe' factor through 'interp', so this analysis and the real run are
consuming the same shape by construction.

>>> :type governed
governed :: Hypo -> Int -> Cofree HarnessF Ctx -> Cofree HarnessF Risk
-}

{- $compaction
Compaction is the summarisation that keeps a long run inside its budget.
'compact' collapses the 'transcript' to a stand-in summary, and is idempotent by
construction (a naive version regrows on each application, which under memory
pressure is an infinite loop):

@
'compact' :: 'S' -> 'S'
@

The claim we make about it is strong: compaction is a coalgebra homomorphism —
invisible in what the agent /does/, even though what it /sees/ (the prompt) must
change. \"Invisible\" needs a checkable meaning, so we observe the /behavioural
shadow/ of a run rather than its full trace. 'observe' folds an 'Ev' list to a
'Behaviour' — a product of four coarser observations (does it 'Done' the same,
the sorted multiset of irreversible tool names, the oracle-call count, the
per-turn call sets) so a divergence /names its kind/ instead of being a bare
boolean.

The law is then 'respectsBehaviour':

@
'respectsBehaviour' :: 'Hypo' -> Int -> ('S' -> 'S') -> 'S' -> ('Behaviour', 'Behaviour')
'respectsBehaviour' h n k s =
  ( 'observe' ('probe' h n ('harness' (k s)))
  , 'observe' ('probe' h n ('harness' s))
  )
@

It probes the compacted state @k s@ and the untouched state @s@ under the same
'Hypo' and returns both 'Behaviour's. Compaction respects behaviour at @s@ when
the two are equal. It returns the /pair/ rather than a 'Bool' on purpose: when
they differ, the caller can see which of the four components diverged and report
a rate per component. A high defect rate is a finding about that 'Hypo' and that
state, not a bug to be hidden — which is where the tour ends and the experiments
begin.

>>> :type respectsBehaviour
respectsBehaviour
  :: Hypo -> Int -> (S -> S) -> S -> (Behaviour, Behaviour)
-}
