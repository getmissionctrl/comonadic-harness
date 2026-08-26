{-# LANGUAGE DerivingVia #-}

-- | Counterfactual analysis — the /analysis/ half of the design, twin to
-- 'Harness.Run'.
--
-- __What.__ A 'Cofree' 'HarnessF' tree branches on the oracle and the world,
-- neither of which the harness controls, so you cannot in general fold it to a
-- single answer. Fix a 'Hypo' — a pure, hypothetical stand-in for both seams —
-- and the branching collapses to one path; now the tree /can/ be folded, and
-- this module folds it to forecasts.
--
-- __Why.__ The point of carrying the whole future as a lazy tree is to be able
-- to /score/ it before acting. 'probe' collapses the tree to a trace; 'assess'
-- reduces that trace to a 'Risk'; 'governed' lifts 'assess' across every
-- reachable node with the comonadic 'Control.Comonad.extend', so that
-- 'Control.Comonad.extract' at any node reads that node's own forecast — a
-- /pre-action gate/. Because 'probe' is built from the same
-- 'Harness.Interp.interp' as 'Harness.Run.run', the forecast is faithful to
-- what a run would do /by construction/, not by a separately maintained second
-- interpreter (§16.1). [established]
--
-- __The two spellings of accumulated risk.__ 'governed' scores each node by
-- re-probing its entire future (@extend assess@, quadratic in depth).
-- 'governedScan' computes the /same/ suffix-sums along the hypo path with a
-- single linear right scan over per-node 'localRisk' contributions. That the
-- two agree is the D1 reconciliation (§16.3).
--
-- __Cross-references.__ Execution twin: 'Harness.Run.run'. Shared kernel:
-- 'Harness.Interp.interp'. The 'Hypo' type and the path collapse:
-- 'Harness.Path.takeWalk'. The outer loop that reads 'assess' as a trigger:
-- 'Harness.Evolve.outerLoop'.
module Harness.Probe
  ( -- * The hypothesis
    Hypo (..)
    -- * Collapsing the tree to a trace
  , probe
    -- * Scoring a future
  , Risk (..)
  , assess
    -- * The comonadic gate
  , governed
    -- * The linear reconciliation (D1)
  , localRisk
  , governedScan
    -- * Bridges to the agreement law
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

-- | Drive the harness purely to a bounded depth under a 'Hypo', collecting the
-- event trace.
--
-- __What.__ The pure twin of 'Harness.Run.run'. It walks the /same/ tree with
-- the /same/ 'Harness.Interp.interp', but substitutes the @Hypo@'s
-- 'Harness.Path.guessOracle' and 'Harness.Path.guessWorld' for the real seams,
-- lifting each into @pure@, and — where 'Harness.Run.run' discards the trace and keeps the
-- 'Outcome' — 'probe' does the opposite: it keeps the @[Ev]@ trace.
--
-- __How.__ One line, because it is 'Harness.Interp.interp' in the @Writer [Ev]@
-- monad; @Control.Monad.Writer.execWriter@ runs it purely and returns just the
-- accumulated trace. The depth bound @n@ is the horizon: without it a
-- non-halting hypothetical future would diverge, whereas analysis must be
-- finite. [established]
--
-- __Gotcha.__ Because 'Harness.Run.run' and 'probe' are the /one/ interpreter, they cannot
-- disagree on the path — that is the agreement law (§16.1), not a coincidence.
-- What they can differ on is only the seams you feed in: a crude 'Hypo' yields
-- a crude forecast.
probe :: Hypo -> Int -> Cofree HarnessF Ctx -> [Ev]
probe h n w =
  execWriter (interp (pure . guessOracle h) (pure . guessWorld h) n w)

-- | A forward-looking score of a node's __own future__ under a hypothesis: how
-- far it runs, whether it terminates, which irreversible tools it will touch,
-- and how many compactions it will trigger.
--
-- __Why every field is a monoid.__ Each field is chosen so that combining two
-- adjacent stretches of a path is just @(<>)@ on the field: 'Data.Monoid.Sum'
-- for counts, 'Data.Monoid.Any' for \"does it happen at all\", @[String]@ for
-- accumulating the offending tools. That makes the whole record a 'Monoid'
-- /generically/ via @Generically Risk@ (§16.3), which is exactly what lets the
-- accumulated future risk be computed as a monoidal scan ('governedScan')
-- rather than a re-probe at every node — the D1 rewrite. [established]
data Risk = Risk
  { stepsAhead :: Sum Int
    -- ^ Number of interpreter events between here and the horizon — the /length/
    -- of the forecast path counted in 'Harness.Interp.Ev's, not tree nodes (a
    -- refusing 'Render' emits two). How much future is being scored.
  , terminates :: Any
    -- ^ @Any True@ iff an 'Harness.Interp.Ended' event occurs within the
    -- horizon, i.e. the machine 'Halt's before fuel runs out. This is the field
    -- 'Harness.Evolve.outerLoop' reads as its trigger: a coalgebra whose
    -- forecast does /not/ terminate is discarded unrun.
  , irreversible :: [String]
    -- ^ The names of the irreversible tools (@\"write\"@, @\"commit\"@) the
    -- forecast will 'Harness.Alphabet.Perform'. Accumulated as a list, not a
    -- count, so the /which/ survives — a gate can veto on the identity of the
    -- tool, not merely its number.
  , compactions :: Sum Int
    -- ^ How many 'Harness.Alphabet.Overflow' refusals the forecast provokes —
    -- i.e. how often the context must be summarised. The headline metric of the
    -- compaction experiment (E1); a high count under a realistic 'Hypo' is a
    -- designed finding, not a defect.
  }
  deriving stock (Eq, Show, Generic)
  deriving (Semigroup, Monoid) via Generically Risk

-- | Score the entire bounded future of a node by collapsing it to a trace and
-- reducing.
--
-- __What.__ Run 'probe' to depth @n@ under 'Hypo' @h@, then fold the resulting
-- @[Ev]@ into a 'Risk': count the events ('stepsAhead'), detect any
-- 'Harness.Interp.Ended' ('terminates'), collect the irreversible
-- 'Harness.Alphabet.Perform's ('irreversible'), and count the
-- 'Harness.Alphabet.Overflow' refusals ('compactions').
--
-- __Why.__ This is the single-node scoring function the whole module is built
-- around: 'governed' lifts it across the tree, 'governedScan' reconciles it
-- with a linear scan, and 'Harness.Evolve.outerLoop' reads its 'terminates'
-- field as a go/no-go trigger.
--
-- __Gotcha.__ 'assess' scores the future /reachable within @n@/. If the
-- machine does not 'Halt' inside the horizon, 'terminates' is @Any False@ and
-- the other fields describe only the truncated prefix; widen @n@ to see
-- further. The per-node event bookkeeping it depends on is duplicated, and must
-- stay in step with, 'localRisk' (see there).
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

-- | The comonadic gate: re-annotate every reachable node of the tree with
-- 'assess' of /that node's/ own future.
--
-- __What.__ @governed h n = 'Control.Comonad.extend' ('assess' h n)@. Where the
-- incoming tree is annotated with 'Harness.State.Ctx' (what the model sees at
-- each node), the outgoing tree is annotated with 'Risk' (what each node's
-- future looks like). The shape ('HarnessF' layer) is untouched — only the
-- annotation changes.
--
-- __Why 'Control.Comonad.extend'.__ 'assess' scores /one/ node's future.
-- 'Control.Comonad.extend' is precisely the comonadic operation that lifts a
-- \"function of a whole substructure\" to \"replace every substructure by that
-- function's value\": it runs 'assess' at the root, at every child, at every
-- grandchild, threading each node its /own/ subtree. So the result is a forecast
-- co-located with every state the machine could be in.
--
-- __How you read it.__ @'Control.Comonad.extract' (governed h 32 w)@ is the
-- 'Risk' at the /current/ node — the pre-action gate. A supervisor consults
-- this before letting the step proceed: e.g. block if @'irreversible'@ is
-- non-empty, or if @'terminates'@ is @Any False@. (@extract . governed@
-- recovers @assess@ at the root; see the tutorial's @demoGateEqualsRoot@.)
--
-- __Gotcha.__ This is the /quadratic/ spelling: 'Control.Comonad.extend'
-- re-probes the full future at every node, so scoring a whole path of depth
-- @d@ costs O(d²). For the accumulated-risk-along-the-path use, prefer the
-- linear 'governedScan', which agrees with this at every node (§16.3, D1).
governed :: Hypo -> Int -> Cofree HarnessF Ctx -> Cofree HarnessF Risk
governed h n = extend (assess h n)

-- | The one-node contribution to 'Risk' under a 'Hypo' — what __this__ node
-- alone adds to the trace, /without/ re-probing its future.
--
-- __What.__ Look only at the current node's 'HarnessF' shape and return the
-- 'Risk' summand for the event(s) 'Harness.Interp.interp' would emit at that
-- node — nothing about its successors. It is the per-node bookkeeping that,
-- summed along a path, reconstructs 'assess'.
--
-- __Why.__ 'assess' at every node re-walks that node's whole future, which is
-- quadratic across a path. But 'assess' over a path is just a fold of the same
-- per-node events, and each field of 'Risk' is a monoid — so if we can name the
-- one-node summand, a single scan totals it. 'localRisk' /is/ that summand; it
-- is what turns the O(d²) 'governed' into the O(d) 'governedScan' (D1, §16.3).
-- [established]
--
-- __How the counts are derived (mirrors 'Harness.Interp.interp' exactly).__ A
-- 'Harness.Alphabet.Halt' emits @[Ended o]@ — 1 event, and sets 'terminates'.
-- A 'Harness.Alphabet.Perform' emits @[Did c]@ — 1 event, plus the tool name if
-- irreversible. A 'Harness.Alphabet.Render' emits @[Asked mode]@ and, /if the
-- oracle guess refuses/, ALSO @[Refused e]@ — so a refusing 'Harness.Alphabet.Render'
-- contributes 2 to 'stepsAhead', and an 'Harness.Alphabet.Overflow' refusal
-- additionally contributes 1 to 'compactions'.
--
-- __Gotcha.__ This case analysis duplicates the emission discipline of
-- 'Harness.Interp.interp'; if that ever changes, this must change in lockstep or the D1 law
-- breaks. The law test is the tripwire — it is /why/ the reconciliation is a
-- checked property rather than a comment.
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

-- | Accumulated 'Risk' along the hypo path, by a right scan — __linear__ in
-- depth. The efficient twin of 'governed'.
--
-- __What.__ A list of 'Risk's, one per node on the path the 'Hypo' selects,
-- where element @i@ is the accumulated future risk /from node @i@ onwards/.
--
-- __How.__ Under a 'Hypo' the branching tree collapses to a single path
-- ('Harness.Path.takeWalk'). Map 'localRisk' over that path to get each node's
-- own one-node summand, then @'scanr1' (\<\>)@ to form __suffix sums__: element
-- @i@ is @mconcat@ over @path[i..end]@. Because 'localRisk' reproduces exactly
-- the events 'Harness.Interp.interp' emits, that suffix sum equals the fold
-- 'assess' would compute at node @i@.
--
-- __Why.__ 'governed' re-probes the whole future at /every/ node, O(depth²).
-- This walks the path once and reuses the monoid, O(depth). Its head agrees
-- with @'assess' h n w@ at the root, and each element agrees with 'assess' at
-- the corresponding node — provided the run 'Halt's within the horizon @n@;
-- that agreement is the D1 reconciliation law (§16.3). [established]
--
-- __Gotcha.__ @'scanr1'@ is undefined on the empty list, but 'Harness.Path.takeWalk'
-- with @n >= 1@ always yields at least the starting node, so a non-zero horizon
-- keeps this total. Beyond the horizon the two spellings can diverge (the
-- truncated future is scored differently), which is why the law is stated for
-- runs that terminate within @n@.
governedScan :: Hypo -> Int -> Cofree HarnessF Ctx -> [Risk]
governedScan h n = scanr1 (<>) . map (localRisk h) . takeWalk h n

-- | Lift a 'Hypo' into a pure 'Env', so the /same/ 'Harness.Run.run' that
-- drives against a live provider can be driven against the hypothesis.
--
-- __What.__ Package the @Hypo@'s two guessing functions as an 'Env' in any
-- 'Applicative' @m@, each seam wrapped in @pure@.
--
-- __Why.__ This is the bridge that makes the agreement law (§16.1, Task 14)
-- expressible: it lets us compare @'Harness.Run.run' ('liftHypo' h)@ — the real
-- driver on a pure environment — against @'outcomeOf' ('probe' h n)@ — the pure
-- prober's own verdict. If those two ever disagreed, the shared-interpreter
-- claim would be false; that they cannot is the whole point of routing both
-- through 'Harness.Interp.interp'. [established]
liftHypo :: Applicative m => Hypo -> Env m
liftHypo h = Env (pure . guessOracle h) (pure . guessWorld h)

-- | Extract the terminal 'Outcome' from a trace, if the run 'Halt'ed within the
-- horizon.
--
-- __What.__ Scan the @[Ev]@ for the first 'Harness.Interp.Ended' and return its
-- 'Outcome'; @Nothing@ if the trace holds none (fuel exhausted before 'Halt').
--
-- __Why.__ 'probe' keeps the whole trace, but the agreement law compares
-- /outcomes/. 'outcomeOf' is the projection from the analysis artefact (the
-- trace) back to the execution artefact (the 'Outcome') that 'Harness.Run.run'
-- returns directly, so the two sides of the law are the same type.
outcomeOf :: [Ev] -> Maybe Outcome
outcomeOf evs = case [o | Ended o <- evs] of
  (o : _) -> Just o
  []      -> Nothing
