{-# LANGUAGE DerivingVia #-}

-- | Counterfactual analysis. The tree branches on things you do not control,
-- so you cannot fold it — but you can fold it under a 'Hypo', a pure stand-in
-- for the oracle and world, which collapses the branching to a path.
module Harness.Probe
  ( Hypo (..)
  , probe
  , Risk (..)
  , assess
  , governed
  , liftHypo
  , outcomeOf
  ) where

import Control.Comonad (extend)
import Control.Comonad.Cofree (Cofree)
import Control.Monad.Writer (execWriter)
import Data.Monoid (Sum (..), Any (..))
import GHC.Generics (Generic, Generically (..))
import Harness.Alphabet
import Harness.Interp (Ev (..), interp)
import Harness.Run (Env (..))
import Harness.State (Ctx)

-- | A pure model of the oracle and the world. As crude or as sharp as you like;
-- the forecast is only ever as good as this.
data Hypo = Hypo
  { guessOracle :: Request -> Either Refusal Response
  , guessWorld  :: Call -> Obs
  }

-- | Drive the harness purely to a bounded depth, collecting the event trace.
-- One line, because it is just 'interp' in the 'Writer' monad. [established]
probe :: Hypo -> Int -> Cofree HarnessF Ctx -> [Ev]
probe h n w =
  execWriter (interp (pure . guessOracle h) (pure . guessWorld h) n w)

-- | A forward-looking assessment of a node's own future. Every field carries a
-- monoid, so the 'Monoid' instance derives generically (§16.3) — which is what
-- makes the D1 scan rewrite (Task 19) possible.
data Risk = Risk
  { stepsAhead :: Sum Int
  , terminates :: Any
  , irreversible :: [String]
  , compactions :: Sum Int
  }
  deriving stock (Eq, Show, Generic)
  deriving (Semigroup, Monoid) via Generically Risk

assess :: Hypo -> Int -> Cofree HarnessF Ctx -> Risk
assess h n w =
  Risk
    { stepsAhead = Sum (length evs)
    , terminates = Any (any ended evs)
    , irreversible = [tool c | Did c <- evs, tool c `elem` ["write", "commit"]]
    , compactions = Sum (length [() | Refused Overflow <- evs])
    }
  where
    evs = probe h n w
    ended (Ended _) = True
    ended _ = False

-- | Annotate every reachable state with an assessment of its own future.
-- @extract (governed h 32 w)@ is the pre-action gate at the current node.
governed :: Hypo -> Int -> Cofree HarnessF Ctx -> Cofree HarnessF Risk
governed h n = extend (assess h n)

-- | Turn a 'Hypo' into a pure 'Env', so the agreement law (§16.1, Task 14) can
-- compare @run (liftHypo h)@ against @outcomeOf (probe h n)@.
liftHypo :: Applicative m => Hypo -> Env m
liftHypo h = Env (pure . guessOracle h) (pure . guessWorld h)

-- | The terminal outcome of a trace, if it halted within the horizon.
outcomeOf :: [Ev] -> Maybe Outcome
outcomeOf evs = case [o | Ended o <- evs] of
  (o : _) -> Just o
  []      -> Nothing
