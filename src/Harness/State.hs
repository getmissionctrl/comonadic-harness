-- | The harness state @S@ and the three quotients on it:
-- 'project' (lossy, what the model sees), the affordance fold 'afford', and
-- 'view' (the annotation placed on every tree node).
--
-- @S@ is the runtime representation — the thing the coalgebra
-- 'Harness.Coalgebra.step' consumes and evolves. The alphabet ('Harness.Alphabet')
-- is the shape; this module is the memory. The split enforced across the two is
-- invariant 2: __execution consumes the shape, analysis consumes the annotation__.
-- 'project'\/'afford'\/'request' feed execution; 'view' produces the 'Ctx' that
-- only analysis (@probe@\/@governed@) reads. If a field of 'Ctx' ever began to
-- influence which successor is chosen, it would belong in @S@ and in @step@, not
-- here.
--
-- The three quotients are lossy maps out of @S@: 'project' forgets everything
-- but the flattened prompt, 'afford' forgets everything but the tool set, and
-- 'view' bundles what analysis is allowed to see. Compaction is interesting
-- precisely because 'project' is lossy: two different @S@ can project to the same
-- 'Prompt', and the bisimulation law asks when that shared projection means the
-- agent behaves identically.
module Harness.State
  ( Mode (..)
  , Turn (..)
  , S (..)
  , Ctx (..)
  , project
  , allTools
  , afford
  , admit
  , settle
  , request
  , view
  , renderLine
  ) where

import Data.List (isPrefixOf)
import GHC.Generics (Generic)
import Harness.Alphabet

-- | Which of the two turn-shapes the harness is currently in. Both go through
-- the single 'Harness.Alphabet.Ask' constructor; @Mode@ is the bit that tells
-- 'request' and 'afford' which one to build, so the alphabet does not need a
-- separate "summarise" symbol. Flipping the mode is the coalgebra's only
-- response to an 'Harness.Alphabet.Overflow'.
data Mode
  = Working
    -- ^ Ordinary task turns: 'request' offers the mode-dependent tool set and
    -- the prompt is the plain projection.
  | Summarising
    -- ^ A compaction turn: 'afford' offers no tools and 'request' appends a
    -- summarise instruction. The next successful 'Harness.Alphabet.Response'
    -- collapses the transcript to a single 'Summary' and returns to 'Working'.
  deriving stock (Eq, Show, Generic)

-- | One entry in the transcript. The transcript is the agent's whole memory; a
-- 'Turn' is rendered to a prompt line by 'renderLine' and the sequence of them
-- is what 'project' flattens. Compaction replaces a run of turns with a single
-- 'Summary'.
data Turn
  = Assistant Response
    -- ^ A model turn: carries the full 'Harness.Alphabet.Response' (what it
    -- said and which tools it called). An 'Assistant' turn with no
    -- 'Harness.Alphabet.calls' at the head of the transcript in 'Working' mode
    -- is the completion signal.
  | User [(Call, Obs)]
    -- ^ A batch of tool results fed back to the model: each performed (or
    -- repaired) 'Harness.Alphabet.Call' paired with its
    -- 'Harness.Alphabet.Obs'. Grouped into one turn so consecutive tool
    -- observations append to the same 'User' line rather than proliferating.
  | Summary String
    -- ^ A compaction marker. Produced by a 'Summarising' turn (replacing the
    -- transcript it summarises) or by the coalgebra to record a
    -- 'Harness.Alphabet.Malformed' refusal.
  deriving stock (Eq, Show, Generic)

-- | The harness state: the agent's entire runtime memory, and the thing the
-- coalgebra 'Harness.Coalgebra.step' unfolds. This is the concrete carrier —
-- @Cofree HarnessF Ctx@ is only its denotation (invariant 3), never serialised.
-- Generators for the law tests reach @S@ only through public transitions, never
-- by record construction, so no unreachable state is ever measured (§16.7).
data S = S
  { transcript :: [Turn]
    -- ^ The conversation so far, __newest turn first__. 'project' reverses it
    -- before flattening. Compaction rewrites this list down to a single
    -- 'Summary'.
  , pending :: [Call]
    -- ^ Tool calls the model has asked for but that have not yet been performed.
    -- 'Harness.Coalgebra.step' drains this list one 'Harness.Alphabet.Perform'
    -- at a time, having first passed it through 'Harness.Coalgebra.admit' to
    -- reject unafforded calls. Non-empty only in 'Working' mode.
  , budget :: Int
    -- ^ Remaining token budget. Spent in __tokens, not turns__: each successful
    -- turn debits @inTok + outTok@ of its 'Harness.Alphabet.Usage'. Reaching
    -- zero halts the run with 'Harness.Alphabet.Exhausted'. [established]
  , mode :: Mode
    -- ^ The current turn-shape. The single field that lets one
    -- 'Harness.Alphabet.Ask' constructor serve both a task turn and a
    -- summarisation turn.
  , tools :: [ToolSpec]
    -- ^ The tools afforded to THIS session. 'afford' filters this per turn.
    -- The coding demo seeds @tools = allTools@; other agents supply their own.
  , failure :: Maybe String
    -- ^ Set by a terminal 'Harness.Alphabet.Malformed' refusal (see
    -- 'Harness.Coalgebra.working'); when present, 'Harness.Coalgebra.step' halts
    -- with 'Harness.Alphabet.Failed' rather than 'Exhausted', so a decode\/model
    -- death is distinguishable from budget exhaustion (review1 #9). 'Nothing' on
    -- a healthy run.
  }
  deriving stock (Eq, Show, Generic)

-- | The annotation placed on every node of the unfolded tree — the third
-- quotient, produced by 'view'. Read by analysis (@probe@\/@governed@), __never__
-- used by execution to choose a successor (invariant 2). It is a read-only
-- snapshot: the fields it exposes are a strict subset of @S@, chosen so that an
-- analyser can label a node without being able to steer it. If a field here
-- started influencing execution, it would have to move into @S@.
data Ctx = Ctx
  { ctxRequest :: Request
    -- ^ The 'Harness.Alphabet.Request' that would be sent at this node — the
    -- prompt and afforded tools the analyser can inspect without contacting a
    -- provider.
  , ctxBudget :: Int
    -- ^ The remaining 'budget' at this node, so analysis can reason about how
    -- close the run is to 'Harness.Alphabet.Exhausted'.
  , ctxMode :: Mode
    -- ^ The 'mode' at this node, letting a trace distinguish task turns from
    -- summarisation turns (as 'Harness.Interp.Ev' does).
  , ctxRepaired :: [(Call, Obs)]
    -- ^ The pending calls this node rejected as unafforded (D3\/D12), each paired
    -- with its synthetic error 'Obs'. Populated by 'view' from 'settle', so the
    -- annotation matches what actually went on the wire (review1 #6a). Read by
    -- analysis (and the trace labeller) only — it never steers execution
    -- (invariant 2). Empty at a node with no repair.
  }
  deriving stock (Eq, Show, Generic)

-- | Render one 'Turn' to a single prompt line. Factored out so the
-- prefix-stability law (§16.6) can be stated: in 'Working' mode,
-- @project (t : ts) == project ts <> renderLine t@ (appending a turn appends to
-- the end of the prompt, leaving the cached prefix untouched — the property a
-- KV-cache relies on). Keeping this the /only/ turn-to-text function means the
-- law is about one definition, not two that might drift. [established]
renderLine :: Turn -> String
renderLine (Assistant r) = "A: " ++ say r ++ concatMap (\c -> " <" ++ tool c ++ ">") (calls r)
renderLine (User rs)     = "U: " ++ concatMap (\(c, Obs o) -> tool c ++ "=" ++ o ++ " ") rs
renderLine (Summary t)   = "S: " ++ t

-- | Quotient 1: the projection @S -> Prompt@. Lossy (it keeps only the rendered
-- transcript, discarding 'pending', 'budget' and 'mode'), total, and recomputed
-- from scratch each turn rather than cached. The transcript is stored
-- newest-first, so 'project' reverses it to put the prompt in reading order.
-- Its lossiness is the whole point: distinct states sharing a 'Prompt' is the
-- collapse that compaction exploits and the bisimulation law quantifies.
project :: S -> Prompt
project s = Prompt (unlines (map renderLine (reverse (transcript s))))

-- | The default catalogue of tools the harness can offer. 'afford' selects a
-- subset of this list per turn; nothing outside it is ever afforded. Kept as a
-- flat constant so the affordance /policy/ lives entirely in 'afford' rather
-- than being smeared across construction sites.
--
-- __Safety__: @bash@ is deliberately excluded from this catalogue. Running
-- arbitrary shell commands as the harness uid escapes the path sandbox and
-- gives the model unrestricted execution. @bash@ will be re-introduced behind
-- an explicit opt-in world constructor in a later task; it must never be
-- reachable by default. [design]
allTools :: [ToolSpec]
allTools =
  [ ToolSpec "read" "{path:string}"
  , ToolSpec "write" "{path:string,body:string}"
  , ToolSpec "commit" "{msg:string}"
  ]

-- | Quotient 2: the affordance fold @S -> [ToolSpec]@. Mode-dependent and a fold
-- over the transcript, __not a constant__ — this is precisely what makes the
-- interface polynomial (the set of directions available at a node varies with
-- the node). The policy: no tools at all while 'Summarising'; otherwise the
-- full 'allTools', except @commit@ is withheld until a @write@ has
-- __successfully__ completed — that is, its observation does not begin with
-- @"error: "@. A failed write (path-sandbox rejection, unafforded-tool repair,
-- or any other error observation) must not unlock @commit@: the safety
-- invariant is keyed on world state, not on the mere presence of a @write@
-- call in memory. [design, review1 #1]
afford :: S -> [ToolSpec]
afford s
  | mode s == Summarising = []
  | any wrote (transcript s) = tools s
  | otherwise = filter ((/= "commit") . specName) (tools s)
  where
    -- A write counts only if it SUCCEEDED: its observation is not an error.
    -- Failed, rejected, or hallucinated writes (whose Obs begins "error: ") must
    -- not unlock commit — the safety invariant is keyed on world state, not on
    -- the mere presence of a write call in memory (review1 #1). [established]
    wrote (User rs) = any (\(c, Obs o) -> tool c == "write" && not ("error: " `isPrefixOf` o)) rs
    wrote _ = False

-- | The admission pass. Split the model's pending calls into those the current
-- node affords (safe to 'Harness.Alphabet.Perform') and those it does not,
-- pairing each rejected 'Call' with a synthetic error 'Obs' so the model sees
-- its own mistake on the next turn (D3\/D12).
--
-- __Why it lives here.__ It depends only on 'afford' and 'pending', both in this
-- module, and both the coalgebra ('Harness.Coalgebra.step', which drains the
-- afforded calls) and the annotation ('view', which surfaces the rejects for
-- analysis) must classify pending calls the /same/ way. Keeping the single
-- source of that classification here — rather than in @Coalgebra@ — lets 'view'
-- reuse it without an import cycle (@State@ must not import @Coalgebra@). [design]
--
-- __Why a model needs it.__ A live model can ask for a tool it was never offered
-- — a hallucinated name, a schema-invalid call, or a tool gated behind a
-- precondition it has not met (@commit@ before any @write@; see 'afford'). Such a
-- call is neither a 'Harness.Alphabet.Refusal' (the provider did answer) nor a
-- clean 'Harness.Alphabet.Response' to act on, yet the alphabet is closed at
-- three constructors and we refuse to grow it for this. So the mismatch is
-- repaired: the bad call becomes an ordinary observation carrying an error
-- string, and the run continues rather than crashing or stalling. [design]
--
-- __Gotcha — order-preserving.__ @foldr@ keeps the original call order in both
-- partitions, so the afforded calls that survive are performed in exactly the
-- sequence the model asked for: no reordering, no dropping, no deduplication.
-- The membership test is by tool /name/ only ('specName'), not by argument
-- schema — an afforded name with malformed @args@ still reaches the world.
-- [design]
admit :: [ToolSpec] -> [Call] -> ([Call], [(Call, Obs)])
admit specs = foldr classify ([], [])
  where
    classify c (ok, bad)
      | tool c `elem` map specName specs = (c : ok, bad)
      | otherwise = (ok, (c, Obs ("error: tool not afforded: " ++ tool c)) : bad)

-- | Apply one admission pass: fold rejected (unafforded) calls into the
-- transcript as error observations and narrow 'pending' to the afforded calls.
-- Idempotent (a settled state has no rejects), so it is safe to apply at every
-- node without looping. Returns the settled state and the rejects it recorded,
-- so both the coalgebra (which drains the afforded calls) and the annotation
-- (which surfaces the rejects for analysis) work from the same partition —
-- the single source of the repair (review1 #6). [design]
settle :: S -> (S, [(Call, Obs)])
settle s = case admit (afford s) (pending s) of
  (_,  []) -> (s, [])
  (ok, bad) ->
    ( s { transcript = recordAll bad (transcript s), pending = ok }, bad )
  where
    record c o (User rs : ts) = User (rs ++ [(c, o)]) : ts
    record c o ts             = User [(c, o)] : ts
    recordAll bad ts = foldl (\acc (c, o) -> record c o acc) ts bad

-- | Assemble the 'Harness.Alphabet.Request' for the current turn. In 'Working'
-- mode it pairs the plain 'project'ion with the afforded tools. In 'Summarising'
-- mode the request carries a summarisation instruction appended to the prompt
-- and __no tools__ — so compaction goes through the same
-- 'Harness.Alphabet.Ask' constructor as an ordinary turn, needing no new
-- alphabet symbol.
request :: S -> Request
request s = case mode s of
  Working -> Request (project s) (afford s) (toChatMsgs s)
  Summarising ->
    let Prompt p = project s
     in Request (Prompt (p ++ "\n[summarise the above in one line]")) [] []

-- | The structured transcript in reading order, for native chat transport
-- ('Harness.Alphabet.reqMessages'). A 'Summary' becomes a system message, an
-- 'Assistant' turn an assistant message carrying its tool 'calls', and a 'User'
-- batch expands to one tool-result message per (call, obs). This preserves the
-- tool-call structure the flattened 'project' discards; 'project' remains for
-- 'Summarising' compaction and the bisimulation analysis.
toChatMsgs :: S -> [ChatMsg]
toChatMsgs s = concatMap turnMsgs (reverse (transcript s))
  where
    turnMsgs (Summary t)   = [MsgUser t]
    turnMsgs (Assistant r) = [MsgAssistant (say r) (calls r)]
    turnMsgs (User rs)     = [ MsgToolResult c o | (c, o) <- rs ]

-- | Quotient 3: the annotation map @S -> Ctx@ used to label every node of the
-- unfolded tree (@unfold (\\s -> (view s, step s))@ in 'Harness.Coalgebra.harness').
-- It exposes only what analysis is permitted to read — the pending 'request',
-- the remaining 'budget', and the 'mode' — and deliberately withholds the rest
-- of @S@, keeping execution and analysis on their separate sides of invariant 2.
--
-- __Repair honesty.__ 'view' first 'settle's the state, so the 'ctxRequest' it
-- exposes is the /repaired/ request — the one 'Harness.Coalgebra.step' actually
-- emits — and 'ctxRepaired' names the rejected calls that settling folded in.
-- The pre-repair annotation would have disagreed with the wire (review1 #6a).
-- Note @'mode' s' == 'mode' s@ ('settle' never changes the mode), so the mode
-- label is unaffected.
view :: S -> Ctx
view s = let (s', rejects) = settle s
          in Ctx (request s') (budget s') (mode s') rejects
