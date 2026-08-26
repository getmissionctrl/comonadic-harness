-- | Evolution: the outer loop.
--
-- __What.__ The two functions here let the /coalgebra itself/ change between
-- runs while the state @S@ persists — the harness's version of John Boyd's
-- destruction and creation. 'evolve' unfolds a chosen coalgebra from a seed;
-- 'outerLoop' tries successively weaker coalgebras and commits to the first
-- whose forecast says it will terminate.
--
-- __Why it cannot be a constructor.__ You might want to express \"switch the
-- machine\" as an alphabet action, e.g. @Evolve (S -> HarnessF S)@. You cannot:
-- 'HarnessF' must not mention @S@ (invariant 4 — the very wall @agents-exe@ hits
-- with @Evolve (Agent r)@, and the reason the joining function lives outside the
-- functor). Evolution is therefore /fold-then-reunfold/: keep the accumulated
-- @S@, choose a different coalgebra, 'Control.Comonad.Cofree.unfold' again. It
-- is a control structure /around/ the denotation, not a node /within/ it.
--
-- __The computed trigger.__ Boyd's account leaves /when/ to destroy and recreate
-- to judgement. Here the trigger is computed, not guessed: 'outerLoop' reads
-- 'Harness.Probe.assess' — the forecast of a machine that has __not been run__ —
-- and only commits to a coalgebra whose 'Harness.Probe.terminates' field is
-- true. Analysis picks the machine; execution then runs it. [design]
--
-- __Cross-references.__ The forecast: 'Harness.Probe.assess'. Execution:
-- 'Harness.Run.run'. The unfold this wraps: 'Control.Comonad.Cofree.unfold'.
module Harness.Evolve
  ( evolve
  , outerLoop
  ) where

import Control.Comonad.Cofree (Cofree, unfold)
import Data.Monoid (Any (..))
import Harness.Alphabet
import Harness.State (Ctx, S)
import Harness.Run (Env, run)
import Harness.Probe (Hypo, Risk (..), assess)

-- | Unfold a chosen coalgebra from a seed into a fresh denotation tree.
--
-- __What.__ Given a /view/ @v :: S -> Ctx@ (the annotation to place on each
-- node) and a /step/ @k :: S -> HarnessF S@ (the shape and successors), unfold
-- the pair @(v s, k s)@ from the seed @s@ into a 'Cofree' 'HarnessF' tree ready
-- for 'Harness.Run.run' or 'Harness.Probe.probe'.
--
-- __Why the split into @v@ and @k@.__ The pair mirrors the two things a node
-- carries: @k@ produces the /shape/ that execution consumes, @v@ produces the
-- /annotation/ that analysis consumes (invariant 2). 'Control.Comonad.Cofree.unfold'
-- threads them together into the anamorphism. Feeding a /different/ @k@ here —
-- a weaker step function — is precisely how 'outerLoop' swaps machines without
-- touching @S@.
--
-- __Gotcha.__ The tree is a denotation, produced lazily on demand; do not read
-- 'evolve' as building a finite structure (invariant 3). Its depth is however
-- far the consumer walks it.
evolve :: (S -> Ctx) -> (S -> HarnessF S) -> S -> Cofree HarnessF Ctx
evolve v k = unfold (\s -> (v s, k s))

-- | Try successively weaker coalgebras; run the first whose /forecast/ says it
-- will terminate.
--
-- __What.__ Given an execution 'Env', a 'Hypo' for the forecast, and a list of
-- candidate coalgebras @(view, step)@ ordered from strongest to weakest, walk
-- the list: for each, 'evolve' its tree from the seed @s@, 'Harness.Probe.assess'
-- that tree under the 'Hypo', and — if the forecast's 'Harness.Probe.terminates'
-- field is true — 'Harness.Run.run' it and stop. Otherwise move to the next
-- candidate. If the list is exhausted, return @'Stuck' \"no coalgebra left\"@.
--
-- __Why fold-then-reunfold.__ Each candidate is a /different machine/ built from
-- the same seed @s@; switching between them is the destruction–creation the
-- module header describes, and it happens out here in ordinary Haskell because
-- it cannot live inside 'HarnessF' (invariant 4).
--
-- __Why a computed trigger.__ The decision to commit is not a heuristic on the
-- /running/ machine; it reads the future of a machine that has __not been run__.
-- @'getAny' ('terminates' ('Harness.Probe.assess' h 32 w))@ asks the forecast
-- \"does this halt within the horizon?\" and only then spends a real run on it.
-- The @32@ is the forecast horizon: analysis is finite, so a candidate that
-- would halt only /beyond/ 32 steps reads as non-terminating and is skipped —
-- widen it to be more patient. [design]
--
-- __Gotcha.__ Ordering matters: 'outerLoop' commits to the /first/ terminating
-- candidate, so \"weaker\" must come later in the list, or it will run a stronger
-- machine that merely happens to halt. Only 'assess' (pure) is consulted for
-- candidates that are rejected; the live 'Env' is touched exactly once, for the
-- one machine that is chosen.
outerLoop
  :: Env IO
  -> Hypo
  -> [(S -> Ctx, S -> HarnessF S)]
  -> S
  -> IO Outcome
outerLoop _ _ [] _ = pure (Stuck "no coalgebra left")
outerLoop env h ((v, k) : rest) s =
  let w = evolve v k s
   in if getAny (terminates (assess h 32 w))
        then run env w
        else outerLoop env h rest s
