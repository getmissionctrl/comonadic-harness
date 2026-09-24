-- | Compaction and its correctness condition.
--
-- __What.__ /Compaction/ is the operation that collapses a long transcript to a
-- short summary stand-in so the running prompt stays inside the model's context
-- window. 'compact' performs it; the rest of this module is the /law/ that says
-- when it was safe.
--
-- __Why a law at all.__ Compaction rewrites the state the agent is standing on.
-- If that rewrite changed what the agent goes on to /do/, compaction would be a
-- silent behavioural edit hiding inside a memory-management routine — the worst
-- kind of bug, because nothing in the transcript records it. So we demand a
-- correctness condition and /measure/ how often real compaction breaks it.
--
-- __The law.__ Compaction is required to be a /coalgebra homomorphism/: the
-- state @s@ and its image @'compact' s@ must be /bisimilar/ — they may present
-- a different prompt to the model (indeed they must; that is the whole point of
-- compacting), but they must exhibit the same observable behaviour thereafter.
-- Invisible in what the agent /does/, not in what it /sees/. This is the
-- companion of the prefix-stability law in "Harness.State": prefix stability
-- keeps the /cached/ prompt untouched when a turn is appended; compaction
-- deliberately rewrites the prompt and asks only that /behaviour/ survive.
--
-- __How we check it.__ Bisimilarity between two branching trees is not directly
-- decidable here, so we observe the /shadow/ each state casts under a fixed
-- hypothesis: drive both to a fuel bound with 'Harness.Probe.probe' and compare
-- the resulting traces through 'observe'. Crucially the shadow is not a single
-- bit. 'Behaviour' is a /product of four coarser observations/, so when the two
-- disagree the divergence /names its kind/ — halting, irreversible writes,
-- oracle cost, or per-turn call structure — rather than collapsing to an
-- unhelpful @False@ (D10, §16.2).
--
-- __The result is a rate, not a proof.__ A property checked at one state proves
-- nothing (this bit us: the first @respectsBehaviour@ example returned @True@ by
-- coincidence). Experiment E1 samples many reachable states and reports a
-- /violation rate per component/. A high defect rate is a finding about this
-- compaction strategy, not a bug to be hidden. [established]
module Harness.Compaction
  ( compact
  , compactViaSummary
  , Behaviour (..)
  , observe
  , respectsBehaviour
  ) where

import Data.List (sort)
import Data.Maybe (listToMaybe)
import Data.Monoid (Sum (..), Last (..))
import Harness.Alphabet
import Harness.Interp (Ev (..))
import Harness.Path (Hypo (..))
import Harness.Probe (probe)
import Harness.State
import Harness.Coalgebra (harness, summarising)

-- | Collapse the transcript to a summary stand-in.
--
-- __What.__ Keeps the two newest turns and appends an empty @'Harness.State.User' []@
-- marker to stand in for everything older, so the prompt projected from the
-- result is short regardless of how long the original conversation was.
--
-- __Why idempotent by fiat.__ Compaction is triggered under /memory pressure/
-- and may fire repeatedly. It must therefore reach a fixed point:
-- @'compact' ('compact' s) == 'compact' s@. The naive body
-- @take 2 ts ++ ['Harness.State.User' []]@ does /not/ have this property — when
-- the transcript is already short (@|ts| < 2@) each application appends another
-- marker, growing the transcript one turn at a time. Under sustained pressure
-- that is an infinite compaction loop that never shrinks anything. This is
-- defect D11.
--
-- __How the guard works.__ Before rewriting, @alreadyCompact@ asks whether the
-- transcript is already in compacted shape: newest turn an empty
-- @'Harness.State.User' []@ marker /and/ no more than three turns total. If so,
-- the state is returned unchanged, so a second application is the identity and
-- the fixed point is reached after one step. [established]
--
-- __STAND-IN ONLY — not the production path.__ @compact@ is a deterministic
-- truncation stand-in used to exercise the law cheaply in test; it is NOT the
-- compactor a live run uses. The production path is
-- 'Harness.Coalgebra.summarising' (a model-produced summary), reachable via an
-- 'Harness.Alphabet.Overflow' refusal. 'compactViaSummary' (below) makes that
-- real path pure and measurable under a 'Harness.Path.Hypo', so experiment E1
-- can report the behavioural cost of the actual transition the harness takes.
-- [established]
compact :: S -> S
compact s
  | alreadyCompact (transcript s) = s
  | otherwise = s { transcript = take 2 (transcript s) ++ [User []] }
  where
    alreadyCompact ts = case reverse ts of
      (User [] : _) -> length ts <= 3
      _ -> False

-- | The PRODUCTION compaction path, made pure for measurement: flip to
-- 'Harness.State.Summarising', ask the summarise 'Harness.State.request', and
-- apply 'Harness.Coalgebra.summarising' with the hypo's answer. Unlike 'compact'
-- (a truncation stand-in) this is exactly the transition a live run takes when
-- it overflows — its behavioural cost is what the flagship claim should
-- quantify (review1 #7). [established]
compactViaSummary :: Hypo -> S -> S
compactViaSummary h s =
  let s'  = s { mode = Summarising }
      ans = guessOracle h (request s')
   in summarising s' ans

-- | The behavioural shadow of a trace: four components, each with its own
-- algebra, so that two traces are declared behaviourally equal exactly when all
-- four agree.
--
-- __Why four and not one.__ A bare @Bool@ (\"did behaviour change?\") tells you
-- /that/ compaction misbehaved but not /how/, and the how is the whole
-- diagnostic value. By making 'Behaviour' a /product/ of four coarser
-- observations, a divergence localises to a named axis — the task halted
-- differently, or an irreversible tool fired, or the oracle was consulted a
-- different number of times, or the per-turn call structure shifted — and E1 can
-- report a violation /rate/ per component rather than one lumped figure (D10,
-- §16.2).
--
-- __Why these four.__ They are the axes on which a compaction defect actually
-- /matters/: what the agent ultimately decides ('bHalt'), what it did to the
-- world that cannot be undone ('bWrites'), what it cost ('bCalls'), and the
-- shape of its tool use turn by turn ('bTurnSets'). Each field is a monoid or
-- list so the observation composes cleanly over a trace. [design]
data Behaviour = Behaviour
  { bHalt     :: Last Outcome
    -- ^ The terminal 'Outcome', if the trace reached one (@'Data.Monoid.Last'@
    -- keeps the /final/ halt). Answers: does the task end, and end the /same/
    -- way, after compaction?
  , bWrites   :: [String]
    -- ^ The sorted multiset of /irreversible/ tool names invoked (@write@ and
    -- @commit@). These are the calls compaction must never add, drop, or
    -- reorder-into-existence, because they touch the world. Sorted so that a
    -- mere permutation is not counted as a divergence.
  , bCalls    :: Sum Int
    -- ^ The number of oracle consultations (@'Harness.Interp.Asked'@ events).
    -- A proxy for /cost/: if compaction changed how many times the model was
    -- called, it changed the token bill even when the outcome matched.
  , bTurnSets :: [[String]]
    -- ^ The per-turn call sets: one sorted list of tool names per turn, in turn
    -- order. Finer than 'bWrites' (it sees /every/ tool, and /when/) but still
    -- order-insensitive /within/ a turn, because pi runs the calls of a single
    -- turn in parallel (§16.2).
  }
  deriving stock (Eq, Show)

-- | Fold a trace down to its behavioural shadow.
--
-- __What.__ Reduces the raw @['Harness.Interp.Ev']@ trace produced by
-- 'Harness.Probe.probe' to the four-axis 'Behaviour' that the compaction law
-- compares.
--
-- __How.__ 'bHalt' takes the last 'Outcome'; 'bWrites' filters the @'Harness.Interp.Did'@
-- calls to the irreversible tools and sorts them; 'bCalls' counts the
-- @'Harness.Interp.Asked'@ boundaries; 'bTurnSets' groups @'Harness.Interp.Did'@
-- calls into the turns between successive @'Harness.Interp.Asked'@ events and
-- sorts each group.
--
-- __Why the sorting.__ Both 'bWrites' and every 'bTurnSets' entry are sorted so
-- that permuting the /independent/ calls within a single turn is not counted as
-- a divergence: pi runs a turn's calls in parallel, so the trace is a list of
-- multisets, not a list of ordered events (§16.2). @'Harness.Interp.Refused'@
-- and @'Harness.Interp.Repaired'@ events are dropped from the turn grouping — a
-- refusal is not a tool call, and a repaired call never reached the world, so
-- neither carries a performed-tool name to compare. Repairs contribute to none
-- of the four axes, so surfacing them in the trace leaves the compaction rates
-- unchanged. [established]
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
        -- A repaired call is not a performed tool, so it contributes to no turn
        -- set (nor to any other axis): the compaction rates are unchanged by it.
        go acc (Repaired _ _ : rest) = go acc rest
        go acc (Ended _ : _)    = [sort acc]
        go acc []               = [sort acc]

-- | The compaction law, made checkable at a single state.
--
-- __What.__ Drives both the compacted state @k s@ and the raw state @s@ to fuel
-- @n@ under the same hypothesis @h@, and returns the pair of behavioural shadows
-- @('observe' … (k s), 'observe' … s)@. Compaction /respects behaviour at @s@/
-- exactly when the two are equal — that is the bisimilarity check of the module
-- header, reduced to an @Eq@ on 'Behaviour'.
--
-- __Why return the pair, not a @Bool@.__ Equality throws away the diagnosis. By
-- handing back both shadows the caller can see /which/ of the four components
-- diverged and classify the failure, which is what experiment E1 needs to report
-- a rate per component rather than a single pass\/fail.
--
-- __How to use it honestly.__ One evaluation proves nothing about compaction in
-- general — it only witnesses agreement (or not) at the state you happened to
-- pass. Sample @s@ across many /reachable/ states (generated through public
-- transitions, never by hand-constructing @'Harness.State.S'@), and quantify the
-- violation rate. The @k@ parameter is the compaction under test — normally
-- 'compact', but abstracted so a null model (e.g. @id@) can be measured against
-- the same harness for a baseline. [established]
respectsBehaviour :: Hypo -> Int -> (S -> S) -> S -> (Behaviour, Behaviour)
respectsBehaviour h n k s =
  ( observe (probe h n (harness (k s)))
  , observe (probe h n (harness s))
  )
