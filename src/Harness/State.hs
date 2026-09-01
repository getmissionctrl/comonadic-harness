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
  , request
  , view
  , renderLine
  ) where

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

-- | The full catalogue of tools the harness can ever offer. 'afford' selects a
-- subset of this list per turn; nothing outside it is ever afforded. Kept as a
-- flat constant so the affordance /policy/ lives entirely in 'afford' rather
-- than being smeared across construction sites.
allTools :: [ToolSpec]
allTools =
  [ ToolSpec "read" "{path:string}"
  , ToolSpec "bash" "{cmd:string}"
  , ToolSpec "write" "{path:string,body:string}"
  , ToolSpec "commit" "{msg:string}"
  ]

-- | Quotient 2: the affordance fold @S -> [ToolSpec]@. Mode-dependent and a fold
-- over the transcript, __not a constant__ — this is precisely what makes the
-- interface polynomial (the set of directions available at a node varies with
-- the node). The policy: no tools at all while 'Summarising'; otherwise the
-- full 'allTools', except @commit@ is withheld until a @write@ has actually
-- happened, so the model cannot commit work it never wrote. [design]
afford :: S -> [ToolSpec]
afford s
  | mode s == Summarising = []
  | any wrote (transcript s) = allTools
  | otherwise = filter ((/= "commit") . specName) allTools
  where
    wrote (User rs) = any ((== "write") . tool . fst) rs
    wrote _ = False

-- | Assemble the 'Harness.Alphabet.Request' for the current turn. In 'Working'
-- mode it pairs the plain 'project'ion with the afforded tools. In 'Summarising'
-- mode the request carries a summarisation instruction appended to the prompt
-- and __no tools__ — so compaction goes through the same
-- 'Harness.Alphabet.Ask' constructor as an ordinary turn, needing no new
-- alphabet symbol.
request :: S -> Request
request s = case mode s of
  Working -> Request (project s) (afford s)
  Summarising ->
    let Prompt p = project s
     in Request (Prompt (p ++ "\n[summarise the above in one line]")) []

-- | Quotient 3: the annotation map @S -> Ctx@ used to label every node of the
-- unfolded tree (@unfold (\\s -> (view s, step s))@ in 'Harness.Coalgebra.harness').
-- It exposes only what analysis is permitted to read — the pending 'request',
-- the remaining 'budget', and the 'mode' — and deliberately withholds the rest
-- of @S@, keeping execution and analysis on their separate sides of invariant 2.
view :: S -> Ctx
view s = Ctx (request s) (budget s) (mode s)
