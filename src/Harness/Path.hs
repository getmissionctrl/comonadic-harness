-- | The pure path a run takes under a hypothesis. The tree branches on the
-- oracle and the world, which are not under the harness's control; fix a 'Hypo'
-- (a pure stand-in for both) and the branching collapses to a single path.
-- This module holds that collapse so both analysis ('Harness.Probe') and the
-- test generators can share exactly one definition of it (no drift).
module Harness.Path
  ( Hypo (..)
  , takeWalk
  ) where

import Control.Comonad.Cofree (Cofree ((:<)))
import Harness.Alphabet
import Harness.State (Ctx)

-- | A pure model of the oracle and the world. As crude or as sharp as you like;
-- the forecast is only ever as good as this. Lives here rather than in
-- 'Harness.Probe' because it is the thing that turns the branching tree into a
-- path — the subject of 'takeWalk'.
data Hypo = Hypo
  { guessOracle :: Request -> Either Refusal Response
  , guessWorld  :: Call -> Obs
  }

-- | The tree-node path from a node under the hypo (used by the comonad law and
-- the governed scan). Exhaustive, wildcard-free over 'HarnessF': a new
-- constructor must break this too (invariant 1).
takeWalk :: Hypo -> Int -> Cofree HarnessF Ctx -> [Cofree HarnessF Ctx]
takeWalk h fuel = go fuel
  where
    go 0 _ = []
    go n w@(_ :< f) = w : case f of
      Halt _      -> []
      Render q k  -> go (n - 1) (k (guessOracle h q))
      Perform c k -> go (n - 1) (k (guessWorld h c))
