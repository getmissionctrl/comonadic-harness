-- | Evolution: the outer loop. Changing the coalgebra cannot be a 'HarnessF'
-- constructor, because the functor must not mention @S@ (invariant 4 — the same
-- wall agents-exe hits with @Evolve (Agent r)@). So evolution is
-- fold-then-reunfold: keep @S@, swap the coalgebra, 'unfold' again.
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

-- | Unfold a chosen coalgebra from a seed.
evolve :: (S -> Ctx) -> (S -> HarnessF S) -> S -> Cofree HarnessF Ctx
evolve v k = unfold (\s -> (v s, k s))

-- | Try successively weaker coalgebras; run the first whose /forecast/ says it
-- terminates (reading the future of a machine that has not been run). This is
-- destruction–creation with a computed trigger, not a guessed one.
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
