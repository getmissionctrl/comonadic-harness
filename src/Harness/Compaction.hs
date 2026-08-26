-- | Compaction and its correctness condition. The law: compaction is a
-- coalgebra homomorphism, i.e. invisible in what the agent /does/ (not in what
-- it /sees/ — the prompt must change). We check the observable shadow, and we
-- make that shadow a /product of four coarser observations/ so a divergence
-- names its kind (D10, §16.2) rather than being a bare boolean.
module Harness.Compaction
  ( compact
  , Behaviour (..)
  , observe
  , respectsBehaviour
  ) where

import Data.List (sort)
import Data.Maybe (listToMaybe)
import Data.Monoid (Sum (..), Last (..))
import Harness.Alphabet
import Harness.Interp (Ev (..))
import Harness.Probe (Hypo, probe)
import Harness.State
import Harness.Coalgebra (harness)

-- | Collapse the transcript to a summary stand-in. Idempotent by fiat (D11):
-- for @|ts| < 2@ the naive @take 2 ts ++ [User []]@ grows on each application,
-- which under memory pressure is an infinite compaction loop. Guard it.
compact :: S -> S
compact s
  | alreadyCompact (transcript s) = s
  | otherwise = s { transcript = take 2 (transcript s) ++ [User []] }
  where
    alreadyCompact ts = case reverse ts of
      (User [] : _) -> length ts <= 3
      _ -> False

-- | The behavioural observation: four components, each with its own algebra.
-- Two compactions are behaviourally equal iff all four agree.
data Behaviour = Behaviour
  { bHalt     :: Last Outcome          -- ^ does the task end differently?
  , bWrites   :: [String]              -- ^ multiset of irreversible tool names (sorted)
  , bCalls    :: Sum Int               -- ^ oracle call count — did cost change?
  , bTurnSets :: [[String]]            -- ^ per-turn call sets, order-insensitive within a turn
  }
  deriving stock (Eq, Show)

-- | Observe a trace. @bWrites@ and each @bTurnSets@ entry are sorted so that
-- permuting independent calls within a turn is /not/ a divergence (pi runs them
-- in parallel; the trace is a list of multisets, not a list of events, §16.2).
observe :: [Ev] -> Behaviour
observe evs = Behaviour
  { bHalt = Last (listToMaybe [o | Ended o <- evs])
  , bWrites = sort [tool c | Did c <- evs, tool c `elem` ["write", "commit"]]
  , bCalls = Sum (length [() | Asked _ <- evs])
  , bTurnSets = turnSets evs
  }
  where
    -- group Did-calls between successive Asked boundaries, sort each group
    turnSets = go []
      where
        go acc (Asked _ : rest) = sort acc : go [] rest
        go acc (Did c : rest)   = go (tool c : acc) rest
        go acc (Refused _ : rest) = go acc rest
        go acc (Ended _ : _)    = [sort acc]
        go acc []               = [sort acc]

-- | Compaction respects behaviour at @s@ when the compacted and uncompacted
-- states observe /identically/. Returns the 'Behaviour' pair so callers can
-- classify /which/ component diverged (Task 16 reports a rate per component).
respectsBehaviour :: Hypo -> Int -> (S -> S) -> S -> (Behaviour, Behaviour)
respectsBehaviour h n k s =
  ( observe (probe h n (harness (k s)))
  , observe (probe h n (harness s))
  )
