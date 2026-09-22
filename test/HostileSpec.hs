module HostileSpec (spec) where

import Test.Hspec
import Control.Exception (SomeException, evaluate, try)
import Harness.Alphabet
import Harness.Coalgebra (harness)
import Harness.Run (Env (..), run)
import Gen (startState)

-- | E4: under a maximally hostile oracle, the harness NEVER crashes — it always
-- returns some 'Outcome'. The oracle is the only untrusted seam (invariant 5
-- says transient failure never reaches the coalgebra; here we additionally show
-- that adversarial /content/ — hallucinated tools, malformed args, empty
-- responses, spurious 'Malformed'\/'Overflow' refusals, @commit@ with no prior
-- @write@ — is absorbed rather than fatal). Every unafforded call is repaired by
-- the coalgebra's admission pass (Task 20, D3) into a synthetic observation, so
-- the run makes progress and terminates on budget. [established]
spec :: Spec
spec =
  describe "hostile oracle (E4): zero harness crashes" $
    it "run returns Some outcome (no exception) for >= 100 seeds" $ do
      results <- mapM runSeed [0 .. 149 :: Int]
      let crashed = [ n | (n, Left _) <- zip [0 :: Int ..] results ]
          outcomes = [ o | Right o <- results ]
          tally p = length (filter p outcomes)
      -- The done/exhausted split is the real evidence: it shows hostile runs
      -- reach genuine terminal states (a normal 'Done' or a budget 'Exhausted'),
      -- not that they merely fail to crash. Note 'Stuck' is /structurally/ absent
      -- here — 'step' only emits 'Done'\/'Exhausted', and the sole 'Stuck' path
      -- ('Harness.Run.run' on fuel exhaustion) can't fire because @run@ uses
      -- @maxBound@ fuel. So a real halt is @done + exhausted@, asserted below.
      putStrLn
        ( "hostile oracle: ran " ++ show (length results)
            ++ " seeds, crashes=" ++ show (length crashed)
            ++ "; outcomes done=" ++ show (tally isDone)
            ++ " exhausted=" ++ show (tally (== Exhausted)) )
      crashed `shouldBe` []                             -- E4: no exceptions escape
      (tally isDone + tally (== Exhausted)) `shouldBe` length results  -- all halted cleanly
  where
    isDone (Done _)  = True
    isDone _         = False

-- | Run one hostile seed to termination inside a 'try', forcing the 'Outcome' to
-- WHNF so a lazily-thrown error is caught here rather than escaping.
runSeed :: Int -> IO (Either SomeException Outcome)
runSeed seed =
  try @SomeException
    (run (hostileEnv seed) (harness (startState 400)) >>= evaluate)

-- | A hostile environment. The world is benign (it only ever sees afforded calls
-- — the coalgebra guarantees it); all the malice is in the oracle, which cycles
-- through adversarial responses keyed by the seed and the running prompt length
-- so successive turns differ.
hostileEnv :: Int -> Env IO
hostileEnv seed = Env oracle' world'
  where
    world' c = pure (Obs (tool c ++ ":ok"))
    oracle' (Request (Prompt p) _tools _) =
      pure (hostileReply ((seed + length (lines p)) `mod` 8))

-- | Eight flavours of hostility, wildcard-free over the alternatives so adding
-- a case is a deliberate act. Empty responses, hallucinated tool names, bogus
-- args, @commit@\/@write@ ordering violations, and both kinds of 'Refusal'.
hostileReply :: Int -> Either Refusal Response
hostileReply 0 = Left Overflow
hostileReply 1 = Left (Malformed "hostile: undecodable tool call")
hostileReply 2 = Right (Response "" [] (Usage 250 30))                    -- empty, no calls
hostileReply 3 = Right (Response "x" [Call "no_such_tool" "{}"] (Usage 200 40)) -- hallucinated
hostileReply 4 = Right (Response "x" [Call "commit" "{}"] (Usage 200 40))  -- commit, maybe no write
hostileReply 5 = Right (Response "" [Call "read" "!!bad args!!"] (Usage 200 40)) -- malformed args
hostileReply 6 =
  Right (Response "x" [Call "write" "{}", Call "commit" "{}", Call "ghost" "{}"] (Usage 220 50))
hostileReply _ = Right (Response "x" [Call "bash" "{}"] (Usage 180 30))
