module Gen
  ( startState
  , genHypo
  , reachableStates
  , takeWalk
  , genTurn
  , genTurns
  ) where

import Test.QuickCheck
import Control.Comonad.Cofree (Cofree)
import Harness.Alphabet
import Harness.State
import Harness.Coalgebra (harness, step)
import Harness.Path (takeWalk)
import Harness.Probe (Hypo (..))

-- | The genuine initial state — the only hand-written S permitted.
startState :: Int -> S
startState b = S { transcript = [], pending = [], budget = b, mode = Working, tools = allTools, failure = Nothing }

-- | A generated pure oracle/world model. Responses vary by prompt length so
-- runs actually progress and sometimes overflow.
genHypo :: Gen Hypo
genHypo = do
  overflowAt <- choose (3, 8)
  tokIn      <- choose (80, 200)
  toolChoice <- elements ["read", "write", "bash", "commit"]
  pure Hypo
    { guessOracle = \(Request (Prompt p) tools _) ->
        if null tools
          then Right (Response "summary" [] (Usage 300 20))
          else if length (lines p) >= overflowAt
                 then Left Overflow
                 else Right (Response "step" [Call toolChoice "x"] (Usage tokIn 40))
    , guessWorld = \c -> Obs (tool c ++ ":ok")
    }

-- | Reachable @(S, tree)@ pairs, walked at the S level via 'step' and resolved
-- by the hypo. Bounded by fuel. The exhaustive (wildcard-free) case over
-- 'HarnessF' is intentional: a new constructor must break this too.
reachableStates :: Hypo -> Int -> Int -> [(S, Cofree HarnessF Ctx)]
reachableStates h fuel b = go fuel (startState b)
  where
    go 0 _ = []
    go n s = (s, harness s) : case step s of
      Halt _      -> []
      Ask q k  -> go (n - 1) (k (guessOracle h q))
      Perform c k -> go (n - 1) (k (guessWorld h c))

-- | Small random turns, for the prefix-stability law (§16.6).
genTurn :: Gen Turn
genTurn = oneof
  [ Assistant <$> genResponse
  , User <$> resize 3 (listOf ((,) <$> genCall <*> (Obs <$> genTok)))
  , Summary <$> genTok
  ]
  where
    genTok      = elements ["a", "bb", "ccc", "note", "done"]
    genCall     = Call <$> elements ["read", "write", "bash", "commit"] <*> pure "x"
    genResponse = Response <$> genTok <*> resize 3 (listOf genCall) <*> pure (Usage 100 20)

genTurns :: Gen [Turn]
genTurns = resize 6 (listOf genTurn)
