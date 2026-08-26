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
  , localRisk
  , governedScan
  , liftHypo
  , outcomeOf
  ) where

import Control.Comonad (extend)
import Control.Comonad.Cofree (Cofree ((:<)))
import Control.Monad.Writer (execWriter)
import Data.Monoid (Sum (..), Any (..))
import GHC.Generics (Generic, Generically (..))
import Harness.Alphabet
import Harness.Interp (Ev (..), interp)
import Harness.Path (Hypo (..), takeWalk)
import Harness.Run (Env (..))
import Harness.State (Ctx)

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

-- | The one-node contribution to 'Risk' under a hypo — what THIS node adds to
-- the trace, without re-probing its future. This is the summand that makes the
-- monoidal scan (D1, §16.3) possible: it reproduces, per node, exactly the
-- events 'interp' emits for that node, so a scan over a path totals to 'assess'.
--
-- The event bookkeeping mirrors 'Harness.Interp.interp' precisely [established]:
-- a 'Halt' emits @[Ended o]@ (1 event); a 'Perform' emits @[Did c]@ (1 event);
-- a 'Render' emits @[Asked mode]@ and, if the oracle guess refuses, ALSO
-- @[Refused e]@ — so a refusing 'Render' contributes 2 to @stepsAhead@, and an
-- 'Overflow' refusal additionally contributes 1 to @compactions@.
localRisk :: Hypo -> Cofree HarnessF Ctx -> Risk
localRisk h (_ :< f) = case f of
  Halt _      -> mempty { stepsAhead = Sum 1, terminates = Any True }
  Perform c _ ->
    mempty
      { stepsAhead = Sum 1
      , irreversible = [tool c | tool c `elem` ["write", "commit"]]
      }
  Render q _ -> case guessOracle h q of
    -- Asked only: 1 event.
    Right _            -> mempty { stepsAhead = Sum 1 }
    -- Asked + Refused Overflow: 2 events, one of them a compaction.
    Left Overflow      -> mempty { stepsAhead = Sum 2, compactions = Sum 1 }
    -- Asked + Refused (Malformed _): 2 events, no compaction.
    Left (Malformed _) -> mempty { stepsAhead = Sum 2 }

-- | Accumulated 'Risk' along the hypo path, by a right scan — LINEAR in depth.
-- Under a hypo the tree collapses to a path (see 'Harness.Path.takeWalk'), and
-- @'scanr1' (<>)@ over the per-node 'localRisk's yields SUFFIX sums: element @i@
-- is @mconcat@ over @path[i..end]@, i.e. the accumulated future risk at node
-- @i@. Where 'governed' (@extend assess@) re-probes the whole future at every
-- node (O(depth²)), this walks the path once (O(depth)). Its head agrees with
-- @assess h n w@, and each element agrees with 'assess' at the corresponding
-- node once the run halts within the horizon @n@ (§16.3, D1).
governedScan :: Hypo -> Int -> Cofree HarnessF Ctx -> [Risk]
governedScan h n = scanr1 (<>) . map (localRisk h) . takeWalk h n

-- | Turn a 'Hypo' into a pure 'Env', so the agreement law (§16.1, Task 14) can
-- compare @run (liftHypo h)@ against @outcomeOf (probe h n)@.
liftHypo :: Applicative m => Hypo -> Env m
liftHypo h = Env (pure . guessOracle h) (pure . guessWorld h)

-- | The terminal outcome of a trace, if it halted within the horizon.
outcomeOf :: [Ev] -> Maybe Outcome
outcomeOf evs = case [o | Ended o <- evs] of
  (o : _) -> Just o
  []      -> Nothing
