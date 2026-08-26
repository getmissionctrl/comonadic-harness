-- | Task 19 / T7 / defect D1. The monoidal scan for @governed@.
--
-- 'Harness.Probe.governed' re-probes the whole future at every node — O(depth²)
-- along a run's single path. Under a hypo the tree collapses to a path, and
-- 'Risk' is a monoid, so the accumulated future risk is a right scan
-- ('Harness.Probe.governedScan') — O(depth). This suite is the reconciliation:
-- the scan's totals must AGREE with 'assess' (§16.3), plus a before/after
-- timing curve as the deliverable.
module PerfSpec (spec) where

import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
import Control.Comonad.Cofree (Cofree)
import Data.Monoid (Sum (..))
import System.CPUTime (getCPUTime)
import Harness.Alphabet
  (HarnessF, Request (..), Response (..), Usage (..), Call (..), Obs (..))
import Harness.State (Ctx)
import Harness.Coalgebra (harness)
import Harness.Path (Hypo (..), takeWalk)
import Harness.Probe (Risk (..), assess, governedScan)
import Gen (genHypo, reachableStates, startState)

-- | The first reachable tree under a hypo at budget @b@, if any. Mirrors the
-- @firstTree@/@Blind@ pattern in "LawsSpec": a 'Hypo' has function fields, so no
-- 'Show'; we wrap it in 'Blind' for the property.
firstTree :: Hypo -> Int -> Maybe (Cofree HarnessF Ctx)
firstTree h b = case reachableStates h 40 b of
  ((_, w) : _) -> Just w
  []           -> Nothing

-- | Force a list of 'Risk' to normal form cheaply, without a @deepseq@ dep:
-- summing @stepsAhead@ walks every element and every field-carrying constructor.
forceRisks :: [Risk] -> Int
forceRisks = sum . map (getSum . stepsAhead)

spec :: Spec
spec = do
  describe "governedScan agreement with assess (§16.3, D1)" $
    -- A halting horizon (n = 500): every run eventually 'Halt's because budget
    -- decreases monotonically, so at n = 500 the path terminates within horizon
    -- and the suffix sums line up with 'assess' node-for-node.
    prop "head == assess w, and per-node == assess at each path node" $
      forAll (Blind <$> genHypo) $ \(Blind h) ->
        forAll (choose (500, 1500)) $ \b ->
          case firstTree h b of
            Nothing -> property True
            Just w  ->
              let n     = 500
                  path  = takeWalk h n w
                  scan  = governedScan h n w
                  perNode = conjoin
                    [ s === assess h n node
                    | (s, node) <- zip scan path ]
               in case scan of
                    []      -> property True
                    (hd : _) -> hd === assess h n w .&&. perNode

  describe "governed timing curve: O(depth²) vs O(depth) (D1 deliverable)" $
    it "old per-node assess vs governedScan agree on head total; print curve" $ do
      -- A purpose-built hypo that NEVER overflows and spends exactly 1 token per
      -- step, so the path length is controlled by the budget alone (unlike the
      -- generated hypos, which overflow within a handful of lines and so never
      -- produce a long path). Depth is then ~ budget, and the quadratic blowup
      -- of the old per-node @assess@ becomes visible.
      let depths = [10, 100, 1000] :: [Int]
      rows <- mapM timeOne depths
      putStrLn ""
      putStrLn "  governed timing curve (CPU ms), old = map (assess h n) . takeWalk, new = governedScan"
      putStrLn "  depth |     old ms |     new ms | head totals agree"
      mapM_ putStrLn rows

-- | A hypo that always answers with a single-tool response of 1-token usage and
-- never overflows, so a run of budget @b@ walks a path of length ~@b@.
longHypo :: Hypo
longHypo = Hypo
  { guessOracle = \_ ->
      Right (Response "step" [Call "read" "x"] (Usage 1 0))
  , guessWorld  = \c -> Obs (tool c ++ ":ok")
  }

-- | Time both strategies at a target depth and return a formatted table row.
-- The budget is chosen so the path reaches roughly @target@ nodes; the horizon
-- @n@ is set above the depth so the run halts within it (suffix sums line up).
-- The assertion is only that both agree on the head total (the accumulated risk
-- at the current node); no timing threshold — machines vary, the printed curve
-- is the deliverable.
timeOne :: Int -> IO String
timeOne target = do
  -- Each Working cycle spends 1 token and emits Render + Perform (2 nodes), so
  -- budget ~ target/2 gives a path of ~target nodes; the horizon dwarfs it.
  let b = max 1 (target `div` 2)
      n = target * 4 + 100
      w = harness (startState b)
      path = takeWalk longHypo n w
      d    = length path
      old  = map (assess longHypo n) path   -- O(depth²): re-probes at every node
      new  = governedScan longHypo n w      -- O(depth):  single right scan
  (tOld, oldHead) <- timeIt (forceRisks old `seq` headTotal old)
  (tNew, newHead) <- timeIt (forceRisks new `seq` headTotal new)
  oldHead `shouldBe` newHead
  pure $ "  " ++ pad 5 (show d)
      ++ " | " ++ pad 10 (show tOld)
      ++ " | " ++ pad 10 (show tNew)
      ++ " | " ++ show (oldHead == newHead)
  where
    headTotal []      = 0
    headTotal (r : _) = getSum (stepsAhead r)

-- | Time a pure 'Int' computation, forcing it, and report CPU milliseconds.
timeIt :: Int -> IO (Integer, Int)
timeIt x = do
  t0 <- getCPUTime
  r  <- x `seq` pure x
  t1 <- getCPUTime
  pure ((t1 - t0) `div` 1000000000, r)   -- picoseconds -> milliseconds

pad :: Int -> String -> String
pad w s = replicate (max 0 (w - length s)) ' ' ++ s
