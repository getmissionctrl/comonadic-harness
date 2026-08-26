-- | The coalgebra: the entire control flow of the agent, as a pure case
-- analysis returning a functor of successor states. Compare
-- @naiveTilNoToolCallStep@ in agents-exe — same analysis, but returning the
-- shape rather than an action for a separate driver to interpret.
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

-- | Split pending calls into those the current node affords (safe to 'Perform')
-- and those it does not, pairing each rejected call with a synthetic error 'Obs'
-- so the model sees its mistake next turn (D3\/D12). Keeping the alphabet at
-- three constructors, a hallucinated or schema-invalid call is neither a
-- 'Refusal' nor a clean 'Response': it is repaired /in the coalgebra/ into an
-- ordinary observation, and the run continues. [design]
--
-- Order-preserving: @foldr@ keeps the original call order in both partitions, so
-- the afforded calls that survive are performed in the sequence the model asked
-- for (no reordering, no dropping).
admit :: [ToolSpec] -> [Call] -> ([Call], [(Call, Obs)])
admit specs = foldr classify ([], [])
  where
    classify c (ok, bad)
      | tool c `elem` map specName specs = (c : ok, bad)
      | otherwise = (ok, (c, Obs ("error: tool not afforded: " ++ tool c)) : bad)

-- | @step@ is deterministic: it always knows what it does next. What it does
-- not know is what comes back, which is why the successor is a /function/ of
-- the oracle\/world result.
--
-- The admission pass runs first (D3\/D12): every 'Perform' the coalgebra emits
-- carries a 'Call' whose 'tool' is afforded at that node. An unafforded call
-- never reaches the world — its synthetic error 'Obs' is folded into the
-- transcript as a 'User' turn (the same append convention 'Perform' uses for
-- real observations), 'pending' is narrowed to the afforded calls, and we
-- re-enter 'step' on that repaired state. Because the repair is a pure state
-- transition with no oracle\/world direction, re-entering 'step' terminates:
-- the afforded partition is strictly shorter than @pending s@ whenever any call
-- was rejected, and on the next entry @admit@ returns no rejections. [design]
--
-- Mode note: @afford s@ is @[]@ in 'Summarising' mode, so /every/ pending call
-- would be rejected there. This is correct — no tool is offered while
-- summarising — but it is also unreachable: pending calls only arise in
-- 'Working' mode from an 'Assistant' response's @calls@, and the mode is not
-- flipped to 'Summarising' while any call is still pending. [established]
step :: S -> HarnessF S
step s
  | budget s <= 0 = Halt Exhausted
  | otherwise = case admit (afford s) (pending s) of
      -- Some pending calls are unafforded: repair them into synthetic
      -- observations and re-enter with the afforded calls only.
      (ok, bad@(_ : _)) ->
        step $
          s & gfield @"transcript" %~ recordAll bad
            & gfield @"pending" .~ ok
      -- All pending calls (if any) are afforded: proceed as before.
      (ok, []) -> case ok of
        (c : cs) ->
          Perform c $ \o ->
            s & gfield @"transcript" %~ record c o
              & gfield @"pending" .~ cs
        [] -> case (mode s, transcript s) of
          (Working, Assistant r : _)
            | null (calls r) -> Halt (Done (say r))
          (Working, _)     -> Render (request s) (working s)
          (Summarising, _) -> Render (request s) (summarising s)
  where
    record c o (User rs : ts) = User (rs ++ [(c, o)]) : ts
    record c o ts             = User [(c, o)] : ts
    -- Fold the rejected @(Call, Obs)@ pairs into the transcript, reusing the
    -- same 'User'-turn append convention as a performed observation.
    recordAll bad ts = foldl (\acc (c, o) -> record c o acc) ts bad

-- | The 'Working'-mode continuation. Overflow flips to 'Summarising' (the only
-- correct response is a state transition, and the coalgebra is the only thing
-- that can make one). A malformed refusal is terminal.
working :: S -> Either Refusal Response -> S
working s (Left Overflow)      = s & gfield @"mode" .~ Summarising
working s (Left (Malformed m)) =
  s & gfield @"transcript" %~ (Summary ("!" ++ m) :)
    & gfield @"budget" .~ 0
working s (Right r) =
  s & gfield @"transcript" %~ (Assistant r :)
    & gfield @"pending" .~ calls r
    & gfield @"budget" %~ subtract (inTok (usage r) + outTok (usage r))

-- | The 'Summarising'-mode continuation. Success collapses the transcript to a
-- single 'Summary' turn and returns to 'Working'. This is compaction, executed
-- through the ordinary 'Render' path.
summarising :: S -> Either Refusal Response -> S
summarising s (Left _) = s & gfield @"budget" .~ 0
summarising s (Right r) =
  s & gfield @"transcript" .~ [Summary (say r)]
    & gfield @"mode" .~ Working
    & gfield @"budget" %~ subtract (inTok (usage r) + outTok (usage r))

-- | The only constructor for a harness: an annotation and a coalgebra, unfolded.
-- No @Cofree HarnessF Ctx@ exists that is not generated by some coalgebra.
harness :: S -> Cofree HarnessF Ctx
harness = unfold (\s -> (view s, step s))
