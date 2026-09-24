-- | The coalgebra: the entire control flow of the agent, as a pure case
-- analysis returning a functor of successor states. Compare
-- @naiveTilNoToolCallStep@ in agents-exe — same analysis, but returning the
-- /shape/ (a 'HarnessF' /position/) rather than an action for a separate driver
-- to interpret.
--
-- __What lives here.__ 'step' /is/ the control flow — the whole agent loop as
-- one total function @S -> HarnessF S@. It decides, at every state, which
-- of the three alphabet positions comes next ('Ask' to ask the oracle,
-- 'Perform' to run a tool against the world, or 'Halt' to stop) and how the
-- state evolves once the /direction/ (the oracle\/world result) comes back.
-- 'Harness.State.settle' is the repair pass 'step' runs first; 'working' and
-- 'summarising' are the two 'Ask' continuations; 'harness' unfolds 'step' into
-- the 'Cofree' denotation.
--
-- __Why a coalgebra.__ The state transition is separated from the effect. 'step'
-- names the successor as a pure function of an as-yet-unknown result; the
-- effects (calling a real model, running a real tool) are supplied later by an
-- interpreter (@Harness.Interp.interp@). The harness is deterministic — it
-- always knows /what/ it does next — and every source of nondeterminism sits in
-- the directions, which is exactly why 'Control.Comonad.Cofree.duplicate' on the
-- unfolded tree is pure and lazy (see "Harness.Alphabet"). [established]
--
-- __Closed alphabet.__ The @case@ in 'step' is wildcard-free over 'HarnessF' on
-- purpose (invariant 1): a fourth constructor must force a new branch here, in
-- @Harness.Interp.interp@, and in the law tests, or @-Wincomplete-patterns@ has
-- been defeated by a stray wildcard.
module Harness.Coalgebra
  ( step
  , admit
  , working
  , summarising
  , harness
  ) where

import Control.Comonad.Cofree (Cofree, unfold)
import Optics.Core ((.~), (&), (%~))
import Optics.Generic (gfield)
import Harness.Alphabet
import Harness.State

-- | Tokens to debit for one successful turn. Clamps each component to >= 0 (a
-- buggy or hostile provider cannot REFILL the budget) and enforces a minimum of
-- 1, so every successful turn strictly decreases the budget. That minimum is
-- what makes the token budget a genuine liveness bound: with it, a run halts in
-- at most @budget@ turns regardless of what usage the provider reports (F4).
-- [design]
spend :: Usage -> Int
spend u = max 1 (max 0 (inTok u) + max 0 (outTok u))

-- | The coalgebra proper: given a state, return the single next action and, in
-- that action's /direction/, the successor state. @step@ is deterministic — it
-- always knows /what/ it does next. What it does not know is what /comes back/,
-- which is why the successor is a /function/ of the oracle\/world result, not a
-- plain state. This is the whole agent loop; there is no driver logic anywhere
-- else, only interpreters that supply the effects.
--
-- __The cases, in order (wildcard-free over 'HarnessF', invariant 1):__
--
-- * __Terminal decode failure__ (@'failure' s == Just m@): 'Halt' with @'Failed' m@.
--   Checked FIRST so a decode death is surfaced distinctly rather than being
--   masked as 'Exhausted' (review1 #9).
--
-- * __Budget exhausted__ (@'budget' s <= 0@): 'Halt' with 'Exhausted'.
--
-- * __Afforded call waiting__ (@ok@ is @c : cs@): emit @'Perform' c@.
--
-- * __No calls, done__ ('Working' mode, newest turn an 'Assistant' 'Response'
--   with empty @calls@): 'Halt' with @'Done' ('say' r)@.
--
-- * __No calls, keep working__ ('Working' otherwise): 'Ask' the 'request' and
--   continue with 'working'.
--
-- * __No calls, summarising__ ('Summarising'): 'Ask' the summarisation 'request'
--   and continue with 'summarising'.
step :: S -> HarnessF S
step s0 =
  let (s, _rejects) = settle s0
   in case failure s of
        Just m  -> Halt (Failed m)
        Nothing
          | budget s <= 0 -> Halt Exhausted
          | otherwise     -> case pending s of
              (c : cs) ->
                Perform c $ \o ->
                  s & gfield @"transcript" %~ record c o
                    & gfield @"pending" .~ cs
              [] -> case (mode s, transcript s) of
                (Working, Assistant r : _)
                  | null (calls r) -> Halt (Done (say r))
                (Working, _)     -> Ask (request s) (working s)
                (Summarising, _) -> Ask (request s) (summarising s)
  where
    record c o (User rs : ts) = User (rs ++ [(c, o)]) : ts
    record c o ts             = User [(c, o)] : ts

-- | The 'Working'-mode continuation — the direction of the 'Ask' that 'step'
-- emits while working. It is the function through which an oracle answer
-- (a 'Refusal' or a 'Response') becomes the next state. Three cases, one per
-- shape of @'Either' 'Refusal' 'Response'@:
--
-- * __'Overflow'__: flip 'mode' to 'Summarising' and change nothing else. The
--   context grew past the window; the only correct response is a state
--   transition into compaction, and the coalgebra is the only thing that can
--   make one. The next 'step' takes the 'Summarising' branch. [design]
--
-- * __'Malformed' m__: terminal. Set the 'failure' field to @Just m@; the next
--   'step' checks 'failure' FIRST and halts with @'Failed' m@, so a decode death
--   is surfaced as 'Harness.Alphabet.Failed' rather than being masked as
--   'Exhausted' (review1 #9). Transient decode noise never reaches the
--   coalgebra (invariant 5), so a 'Malformed' that /does/ reach it is genuinely
--   unrecoverable.
--
-- * __'Response' r__: the normal move. Push the 'Assistant' turn onto the
--   transcript, set 'pending' to the response's @calls@ (which the next 'step'
--   will 'admit'), and debit the 'budget' by the reported token 'usage'
--   (@'inTok' + 'outTok'@).
working :: S -> Either Refusal Response -> S
working s (Left Overflow)      = s & gfield @"mode" .~ Summarising
working s (Left (Malformed m)) = s & gfield @"failure" .~ Just m
working s (Right r) =
  s & gfield @"transcript" %~ (Assistant r :)
    & gfield @"pending" .~ calls r
    & gfield @"budget" %~ subtract (spend (usage r))

-- | The 'Summarising'-mode continuation — the direction of the 'Ask' 'step'
-- emits while summarising. This is compaction, and it deliberately reuses the
-- ordinary 'Ask' path rather than a bespoke constructor: to the alphabet a
-- summarisation turn is just another ask (see @Harness.State.request@, which
-- appends the summarise instruction and offers no tools). Three cases:
--
-- * __'Overflow'__: give up by zeroing the 'budget'. The context is already too
--   large to fit even a summarisation request; there is nothing smaller left to
--   try, so the next 'step' 'Halt's with 'Exhausted'. [design]
--
-- * __'Malformed' m__: a decode failure on the summarisation turn. Set the
--   'failure' field, which makes the next 'step' halt with @'Failed' m@ rather
--   than 'Exhausted' — consistent with how 'working' handles 'Malformed'
--   (review1 #9). [design]
--
-- * __'Response' r__: success. Collapse the whole transcript to the single
--   'Summary' turn @'say' r@, flip 'mode' back to 'Working', and debit the
--   'budget' by the token 'usage' of the summarisation call itself. The shrunken
--   transcript is what buys the run more room.
summarising :: S -> Either Refusal Response -> S
summarising s (Left Overflow)      = s & gfield @"budget" .~ 0
summarising s (Left (Malformed m)) = s & gfield @"failure" .~ Just m
summarising s (Right r) =
  s & gfield @"transcript" .~ [Summary (say r)]
    & gfield @"mode" .~ Working
    & gfield @"budget" %~ subtract (spend (usage r))

-- | Unfold a starting state into the 'Cofree' denotation of the whole run: at
-- every node the annotation @'view' s@ (a 'Ctx', for analysis) sits over the
-- action @'step' s@ (the shape, for execution), and every direction of that
-- shape unfolds the same way. This is the /only/ way a @Cofree HarnessF Ctx@
-- enters the system — no such tree exists that is not generated by 'step' from
-- some 'S'. That is what lets the laws quantify over \"the harness\" instead of
-- over arbitrary trees.
--
-- __Gotcha — denotation, not representation (invariant 3).__ The 'Cofree' is
-- lazy and (with genuinely branching directions) infinitely wide; it is never
-- materialised, serialised, cached, or handed to a provider. The running system
-- carries only 'S' and 'step'. 'harness' exists so analysis
-- (@Harness.Probe@, the law tests) has a tree to walk, and interpreters
-- (@Harness.Interp.interp@) consume it node by node without ever forcing more
-- than the path actually taken.
harness :: S -> Cofree HarnessF Ctx
harness = unfold (\s -> (view s, step s))
