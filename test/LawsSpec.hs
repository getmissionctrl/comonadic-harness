module LawsSpec (spec) where

import Test.Hspec hiding (pending)
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
import Control.Comonad (duplicate, extract)
import Control.Comonad.Cofree (Cofree ((:<)))
import Harness.Alphabet
import Harness.State
import Harness.Run (run)
import Harness.Probe (Hypo, probe, liftHypo, outcomeOf)
import Harness.Compaction
import Gen

-- | The annotation path to bounded depth, under a hypo.
annPath :: Hypo -> Int -> Cofree HarnessF Ctx -> [Ctx]
annPath h n = map extract . takeWalk h n

firstTree :: Hypo -> Int -> Maybe (Cofree HarnessF Ctx)
firstTree h b = case reachableStates h 20 b of
  ((_, w) : _) -> Just w
  []           -> Nothing

-- | Every 'Perform' node reached under the hypo, paired with the afforded tool
-- names at that node. The afforded set is read from the node's own 'Ctx'
-- annotation (@reqTools (ctxRequest c)@, which is @afford s@ at that node — see
-- 'Harness.State.request'); this is analysis reading the annotation, permitted.
-- Wildcard-free over 'HarnessF' (invariant 1): 'Ask' and 'Halt' contribute
-- nothing, but are matched explicitly.
performNodes :: Hypo -> Cofree HarnessF Ctx -> [(String, [String])]
performNodes h w = concatMap (\(c :< f) -> node c f) (takeWalk h 200 w)
  where
    node c (Perform call _) = [(tool call, map specName (reqTools (ctxRequest c)))]
    node _ (Ask _ _)     = []
    node _ (Halt _)         = []

-- | One 'Perform' observation from 'performNodes' passes the affordance law iff
-- the performed tool is among the afforded names at that node.
afforded :: (String, [String]) -> Property
afforded (performed, tools) =
  counterexample
    ("Perform " ++ show performed ++ " unafforded; afforded=" ++ show tools)
    (performed `elem` tools)

-- | Build an S directly from generated turns. This is NOT a §16.7 violation:
-- 'project' is a pure function of the transcript, so reachability is irrelevant
-- here — we are testing an algebraic law of 'project', not running the coalgebra.
startStateWith :: [Turn] -> S
startStateWith ts = S { transcript = ts, pending = [], budget = 1, mode = Working, tools = allTools }

spec :: Spec
spec = do
  describe "comonad laws (Cofree HarnessF Ctx), bounded depth" $ do
    -- Both laws are provable for 'Cofree' from the 'free' library; they are
    -- asserted here as a regression guard against a bad hand-written 'Functor'
    -- instance on 'HarnessF' or a change of 'Cofree' import.
    prop "extract . duplicate == id (annotation path, depth 12)" $
      forAll (Blind <$> genHypo) $ \(Blind h) -> forAll (choose (100, 1200)) $ \b ->
        case firstTree h b of
          Nothing -> property True
          Just w  -> annPath h 12 (extract (duplicate w)) === annPath h 12 w
    prop "fmap extract . duplicate == id (annotation path, depth 12)" $
      forAll (Blind <$> genHypo) $ \(Blind h) -> forAll (choose (100, 1200)) $ \b ->
        case firstTree h b of
          Nothing -> property True
          Just w  -> annPath h 12 (fmap extract (duplicate w)) === annPath h 12 w

  describe "agreement law: run == probe outcome (§16.1, the value proposition)" $
    prop "outcomeOf (probe h 200 w) == Just (run (liftHypo h) w)" $
      forAll (Blind <$> genHypo) $ \(Blind h) -> forAll (choose (200, 1200)) $ \b ->
        case firstTree h b of
          Nothing -> property True
          Just w  -> ioProperty $ do
            -- 'run' now returns @Either ProviderError Outcome@. A 'Hypo' is a pure
            -- stand-in that never faults, so the live side is always @Right@;
            -- project it back to @Maybe Outcome@ to match the prober's verdict.
            o <- run (liftHypo h) w
            let ran = case o of Right x -> Just x; Left _ -> Nothing
            pure (outcomeOf (probe h 200 w) === ran)

  describe "prefix stability (protects prompt caching, §16.6)" $
    prop "project (t:ts) == project ts <> renderLine t <> newline" $
      forAll genTurns $ \ts -> forAll genTurn $ \t ->
        let Prompt whole = project (startStateWith (t : ts))
            Prompt rest  = project (startStateWith ts)
         in whole === rest ++ renderLine t ++ "\n"

  describe "affordance law (§16.4, D12)" $ do
    -- Real assertion after Task 20's @admit@ pass: every 'Perform' the coalgebra
    -- emits carries a 'Call' whose 'tool' is afforded at that node. We walk the
    -- reachable tree and, at each 'Perform' node, read the afforded tool names
    -- from that node's own 'Ctx' annotation (@reqTools (ctxRequest c)@, which is
    -- @afford s@ at that node — see 'Harness.State.request') and assert the
    -- performed tool is among them. Pre-fix this FAILED: a hypo emitting @commit@
    -- before any @write@ (genHypo can) reached a 'Perform commit' at a node whose
    -- afforded set excludes @commit@.
    prop "probe never emits (Did c) whose tool is unafforded at that node" $
      forAll (Blind <$> genHypo) $ \(Blind h) -> forAll (choose (200, 1200)) $ \b ->
        case firstTree h b of
          Nothing -> property True
          Just w  -> conjoin (map afforded (performNodes h w))

    it "bash is not in the default tool catalogue" $
      map specName allTools `shouldNotContain` ["bash"]

    -- Non-vacuity guard: over a fixed sample the affordance walk must observe at
    -- least one 'Perform' node (otherwise the prop above proves nothing). We
    -- assert a positive count and print it. [design]
    it "affordance walk is non-vacuous: observes Perform nodes across the sample" $ do
      hs <- generate (vectorOf 200 genHypo)
      let seen = [ pn | h <- hs, (_, w) <- reachableStates h 20 600, pn <- performNodes h w ]
      putStrLn ("affordance law: observed " ++ show (length seen) ++ " Perform nodes across sample")
      length seen `shouldSatisfy` (> 0)

  describe "afford: only a successful write unlocks commit (review1 #1)" $ do
    it "a failed write does not unlock commit" $ do
      let s = startStateWith [User [(Call "write" "x", Obs "error: absolute path not allowed: /etc/x")]]
      map specName (afford s) `shouldNotContain` ["commit"]
    it "a successful write unlocks commit" $ do
      let s = startStateWith [User [(Call "write" "notes.md", Obs "wrote 12 bytes to notes.md")]]
      map specName (afford s) `shouldContain` ["commit"]

  describe "compaction violation rate (E1, expected non-zero for real compact)" $ do
    it "no-op compaction scores 0% (baseline null model)" $ do
      r <- measureRate id
      totalPct r `shouldBe` 0
    it "real compaction: report rate + per-component breakdown, no crash" $ do
      r <- measureRate compact
      putStrLn (renderRate r)
      nStates r `shouldSatisfy` (>= 1000)

-- The compaction-rate machinery: a product of four observations, reported as a
-- rate with a per-component breakdown (D10). NOT a boolean.
data Rate = Rate
  { nStates    :: Int
  , diffHalt   :: Int
  , diffWrites :: Int
  , diffCalls  :: Int
  , diffTurns  :: Int
  }

measureRate :: (S -> S) -> IO Rate
measureRate k = do
  hs <- generate (vectorOf 200 genHypo)
  let pairs = [ (h, s) | h <- hs, (s, _w) <- reachableStates h 40 900 ]
      obs (h, s) =
        let (a, b) = respectsBehaviour h 40 k s
         in ( bHalt a /= bHalt b
            , bWrites a /= bWrites b
            , bCalls a /= bCalls b
            , bTurnSets a /= bTurnSets b )
      rs = map obs pairs
  pure Rate
    { nStates    = length rs
    , diffHalt   = length (filter (\(x, _, _, _) -> x) rs)
    , diffWrites = length (filter (\(_, x, _, _) -> x) rs)
    , diffCalls  = length (filter (\(_, _, x, _) -> x) rs)
    , diffTurns  = length (filter (\(_, _, _, x) -> x) rs)
    }

totalPct :: Rate -> Int
totalPct r
  | nStates r == 0 = 0
  | otherwise = 100 * (diffHalt r + diffWrites r + diffCalls r + diffTurns r) `div` (4 * nStates r)

renderRate :: Rate -> String
renderRate r = unlines
  [ "compaction violation rate over " ++ show (nStates r) ++ " reachable states:"
  , "  halt outcome differs:   " ++ pct (diffHalt r)
  , "  write multiset differs: " ++ pct (diffWrites r)
  , "  oracle call count diff: " ++ pct (diffCalls r)
  , "  per-turn call sets diff:" ++ pct (diffTurns r)
  ]
  where
    pct x | nStates r == 0 = "n/a"
          | otherwise = show (100 * x `div` nStates r) ++ "%"
