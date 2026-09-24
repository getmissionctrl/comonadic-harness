{-# LANGUAGE DeriveAnyClass #-}

-- | The closed action alphabet. Three constructors, no escape hatch.
--
-- This module is the polynomial interface functor 'HarnessF' together with the
-- concrete payloads its constructors carry. It is the /shape/ of the agent: the
-- set of things the harness can do and the set of replies it can receive. It
-- deliberately says nothing about state — the coalgebra 'Harness.Coalgebra.step'
-- supplies that (invariant 4: evolution lives outside the functor, so 'HarnessF'
-- must never mention @S@).
--
-- Positions are what the harness /does/; directions (the function arguments) are
-- what it does /not/ control. In 'HarnessF' the positions are 'Request', 'Call'
-- and 'Outcome'; the directions are the @... -> x@ continuations. The harness is
-- deterministic; all nondeterminism lives in the directions, which is exactly
-- why 'Control.Comonad.Cofree.duplicate' on the unfolded tree is pure and lazy.
-- [established]
--
-- The alphabet being __closed__ is the load-bearing property. A fourth
-- constructor is not a local change: it forces a matching case in
-- 'Harness.Interp.interp' (the single interpreter both 'Harness.Run.run' and
-- 'Harness.Probe.probe' factor through) and in the law tests, or
-- @-Wincomplete-patterns@ fails the build (invariant 1). There are no wildcard
-- matches over 'HarnessF' anywhere, so this coupling cannot be silently evaded.
module Harness.Alphabet
  ( Prompt (..)
  , ToolSpec (..)
  , Request (..)
  , ChatMsg (..)
  , Call (..)
  , Obs (..)
  , Usage (..)
  , Response (..)
  , Refusal (..)
  , Outcome (..)
  , HarnessF (..)
  , ReplaySafety (..)
  ) where

import GHC.Generics (Generic)

-- | The text actually handed to the model on a turn: the transcript projected
-- down to a flat prompt string. It is the output of the lossy quotient
-- 'Harness.State.project', so two distinct states can share a 'Prompt' — that
-- collapse is what compaction exploits and what the bisimulation law measures.
-- Wrapped in a @newtype@ so a projected prompt is never confused with an
-- arbitrary 'String' at a call site.
newtype Prompt = Prompt String
  deriving stock (Eq, Show, Generic)

-- | A tool the provider is told it may call. Carried in the 'Request' so it
-- actually reaches the model — the amendment 'reference/Harness.hs' lacked
-- (its @Ask@ carried only a bare prompt, so afforded tools never crossed the
-- wire). The set of specs offered on a turn is computed by the affordance fold
-- 'Harness.State.afford', which is why the interface is polynomial rather than a
-- fixed signature. [established]
data ToolSpec = ToolSpec
  { specName   :: String
    -- ^ The tool's name, e.g. @"read"@ or @"commit"@. This is the key against
    -- which 'Harness.Coalgebra.admit' checks a model's 'Call': a 'tool' whose
    -- name is not among the afforded 'specName's is repaired into a synthetic
    -- error rather than performed.
  , specSchema :: String
    -- ^ A description of the tool's argument shape (a JSON-schema-ish blob such
    -- as @"{path:string}"@). Advisory only — it is shown to the model to shape
    -- its 'args', but the harness does not validate against it here.
  }
  deriving stock (Eq, Show, Generic)

-- | What the model sees on a single turn: the projected prompt plus the tools
-- afforded at that node. Assembled by 'Harness.State.request', which in
-- 'Harness.State.Working' mode pairs @project@ with @afford@, and in
-- 'Harness.State.Summarising' mode appends a summarisation instruction and
-- offers /no/ tools. A 'Request' is exactly the payload of a 'Ask' position
-- and the thing recorded in the annotation 'Harness.State.Ctx' for analysis.
data Request = Request
  { reqPrompt :: Prompt
    -- ^ The prompt text for this turn, i.e. the 'Harness.State.project'ion of
    -- the transcript (possibly with a trailing summarisation instruction in
    -- 'Harness.State.Summarising' mode).
  , reqTools :: [ToolSpec]
    -- ^ The tools offered on this turn. Empty while summarising; otherwise the
    -- mode-dependent affordance set. This list is what 'Harness.Coalgebra.admit'
    -- treats as the ground truth of what the model was permitted to call.
  , reqMessages :: [ChatMsg]
    -- ^ The STRUCTURED transcript for this turn (reading order), so a provider
    -- can send native chat messages (system / assistant-with-tool_calls / tool
    -- results) instead of the lossy flattened 'reqPrompt'. Empty in
    -- 'Harness.State.Summarising' mode (compaction legitimately uses the flatten)
    -- and empty for providers that only consume 'reqPrompt'. Additive: 'reqPrompt'
    -- and the bisimulation laws stated on it are unchanged.
  }
  deriving stock (Eq, Show, Generic)

-- | A tool call the model has asked for: a name and its (unparsed) arguments.
-- Produced by the model inside a 'Response' and carried in a 'Perform' position
-- when — and only when — 'Harness.Coalgebra.admit' has confirmed the 'tool' is
-- afforded. An unafforded call is not a 'Refusal' and not a clean 'Response'; it
-- is repaired in the coalgebra into an error 'Obs' and the run continues (D3\/D12).
data Call = Call
  { tool :: String
    -- ^ The name of the tool to invoke. Checked against the afforded
    -- 'ToolSpec' 'specName's; an unmatched name is the trigger for repair.
  , args :: String
    -- ^ The raw argument payload the model supplied (typically a JSON string).
    -- Passed opaquely to the world; this module does not parse it.
  }
  deriving stock (Eq, Show, Generic)

-- | The world's reply to a performed 'Call' — the observation fed back into the
-- next turn. It is the direction of a 'Perform' position: the harness controls
-- /that/ it performs the call, never /what/ comes back, so the successor state
-- is a function @Obs -> x@. A synthetic error 'Obs' is also how the coalgebra
-- reports an unafforded call back to the model. Wrapped in a @newtype@ to keep
-- a tool observation distinct from arbitrary text.
newtype Obs = Obs String
  deriving stock (Eq, Show, Generic)

-- | A structured transcript entry for native chat transport (see
-- 'Request.reqMessages'). Provider-neutral: a provider maps these to its own
-- message type (e.g. Ollama's system\/assistant-with-tool_calls\/tool roles).
-- This preserves the tool-call structure a capable agentic model expects,
-- instead of the flattened 'Harness.State.project'ion which is retained only for
-- compaction and the bisimulation analysis.
data ChatMsg
  = MsgUser String          -- ^ the task / compacted context (a 'Summary' turn),
                            --   rendered as a USER message (chat APIs require a
                            --   user turn; the seed task is the user's request)
  | MsgAssistant String [Call] -- ^ the model's text plus the tool calls it made
  | MsgToolResult Call Obs  -- ^ one tool result, paired with the call it answers
  deriving stock (Eq, Show, Generic)

-- | Token usage as reported by the provider for one 'Response'. Budget is spent
-- in tokens, not turns (see 'Harness.State.budget'): the coalgebra subtracts
-- @inTok + outTok@ from the remaining budget after each successful turn, so a
-- verbose turn costs more than a terse one regardless of turn count. [established]
data Usage = Usage
  { inTok  :: Int
    -- ^ Prompt (input) tokens the provider billed for this turn.
  , outTok :: Int
    -- ^ Completion (output) tokens the provider billed for this turn.
  }
  deriving stock (Eq, Show, Generic)

-- | A successful reply from the oracle: what the model said, any tools it wants
-- to call, and the token cost. It is the @Right@ half of the 'Ask' direction
-- (@Either Refusal Response@). An empty 'calls' list in 'Harness.State.Working'
-- mode is how the agent signals it is finished — the coalgebra turns it into a
-- @Halt (Done ...)@.
data Response = Response
  { say   :: String
    -- ^ The model's natural-language output for this turn. Recorded in the
    -- transcript as the assistant line, and returned as the final answer when a
    -- turn ends the run.
  , calls :: [Call]
    -- ^ The tool calls the model requested, in the order it asked for them.
    -- Empty means "no more tools" — a completion signal in 'Harness.State.Working'
    -- mode. 'Harness.Coalgebra.admit' preserves this order when performing them.
  , usage :: Usage
    -- ^ The provider-reported token cost of producing this 'Response', debited
    -- from the budget.
  }
  deriving stock (Eq, Show, Generic)

-- | The only failures the coalgebra may see. Everything transient (429, 5xx,
-- socket timeouts, transient decode noise) is the provider's problem and is
-- absorbed by @Env@ decorators before it can reach here (invariant 5): a
-- 'Refusal' is a designed, terminal-or-transformative signal, not an accident of
-- the network. It is the @Left@ half of the 'Ask' direction.
data Refusal
  = Overflow
    -- ^ The context window was exceeded. This is the /only/ recoverable
    -- refusal: the coalgebra's 'Harness.Coalgebra.working' continuation responds
    -- by flipping to 'Harness.State.Summarising' mode, which is compaction. It
    -- is not a failure of the run, it is the trigger for the run to compact.
  | Malformed String
    -- ^ A terminal decode failure the provider could not repair (payload carries
    -- the diagnostic). Unlike an unafforded 'Call' — which is repaired into an
    -- 'Obs' and continued — a 'Malformed' refusal ends the run: the coalgebra
    -- records it and zeroes the budget.
  deriving stock (Eq, Show, Generic)

-- | How a run ends. Carried by the terminal 'Halt' position, so an 'Outcome' is
-- a leaf of the unfolded tree — it has no direction and thus no successor.
data Outcome
  = Done String
    -- ^ The agent finished cleanly. The payload is the final assistant 'say',
    -- reached when a 'Harness.State.Working'-mode 'Response' carries no tool
    -- 'calls'.
  | Exhausted
    -- ^ The budget ran out before the agent finished. Emitted when
    -- 'Harness.State.budget' reaches zero without a terminal decode failure.
  | Failed String
    -- ^ A terminal decode\/model failure the provider could not repair (payload
    -- carries the diagnostic). Distinct from 'Exhausted' (budget ran out) so a
    -- decode death is not mistaken for ordinary budget exhaustion (review1 #9).
    -- Fires when 'Harness.State.failure' is set by a 'Malformed' refusal reaching
    -- 'Harness.Coalgebra.working'.
  | Stuck String
    -- ^ The agent could make no progress for a non-budget reason (payload
    -- carries the explanation). [design]
  deriving stock (Eq, Show, Generic)

-- | The interface functor: the polynomial whose positions are the harness's
-- actions and whose directions are the replies it awaits. Unfolding the
-- coalgebra 'Harness.Coalgebra.step' through this functor gives the denotational
-- @Cofree HarnessF Ctx@ tree — though @Cofree@ is a denotation, not a runtime
-- representation (invariant 3): the implementation carries @S@ and the
-- coalgebra, never a serialised tree.
--
-- Closed. A fourth constructor requires a matching case in 'Harness.Interp.interp'
-- and the law tests, or @-Wincomplete-patterns@ will (correctly) fail the build
-- (invariant 1). The @x@ in each direction is the successor node; 'Functor' maps
-- over those successors and is derived precisely because 'HarnessF' never
-- mentions @S@.
data HarnessF x
  = Ask Request (Either Refusal Response -> x)
    -- ^ Ask the oracle. The 'Request' is the position (prompt + afforded tools);
    -- the direction is @Either Refusal Response -> x@ — the harness controls the
    -- question, not the answer. This one constructor serves both a task turn and
    -- a summarisation turn; which it is depends on 'Harness.State.mode', not on a
    -- separate alphabet symbol.
  | Perform Call (Obs -> x)
    -- ^ Run a tool against the world. The 'Call' is the position; the direction
    -- @Obs -> x@ is the world's reply. The coalgebra only ever emits a 'Perform'
    -- for an /afforded/ 'Call' (invariant of 'Harness.Coalgebra.admit'), so an
    -- unafforded call never reaches the world through this position.
  | Halt Outcome
    -- ^ Stop. A leaf: no direction, no successor. The 'Outcome' says how the run
    -- ended.
  deriving stock (Functor, Generic)

-- | Whether a 'Call' may be safely re-performed after a crash and resume —
-- borrowed from haskell-agent as groundwork for D4 (persist\/resume), which is
-- otherwise unbuilt. 'ReplaySafe': idempotent or read-only, re-run freely.
-- 'ReplayUnsafe': already applied an external side effect, must not re-run.
-- 'ReplayUnknown': cannot establish; treat conservatively (do not re-run). No
-- code consumes this yet; it exists so a future resume path has a vocabulary for
-- what is safe to repeat. [design] [unbuilt: the resume engine]
data ReplaySafety = ReplaySafe | ReplayUnsafe | ReplayUnknown
  deriving stock (Eq, Show, Generic)
