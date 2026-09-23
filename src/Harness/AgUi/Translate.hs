-- | Pure builders that turn one oracle reply or one world observation into the
-- AG-UI events it produces, threading a small 'RunState' so message\/tool ids
-- are stable and state deltas are accurate. The tracing decorator
-- ('Harness.AgUi.Sink.traceEnv') calls these; keeping them pure makes the wire
-- mapping unit-testable without IO, and keeps all AG-UI knowledge out of the
-- coalgebra (invariant 2: this is presentation, not execution).
module Harness.AgUi.Translate
  ( RunState
  , initRunState
  , modeOf
  , budgetOf
  , runStartEvents
  , oracleEvents
  , refusalEvents
  , worldEvents
  , runFinishEvents
  , forecastEvent
  ) where

import Data.Aeson (Value, object, toJSON, (.=))
import Data.Monoid (Any (..), Sum (..))
import Data.Text (Text, pack)
import Harness.Alphabet
import Harness.State (Mode (..))
import Harness.Probe (Risk (..))
import Harness.AgUi.Event

-- | The id\/budget\/mode threading state for a single run's event construction.
-- Not the harness 'Harness.State.S' — it is the minimal shadow the /wire mapping/
-- needs: enough to mint stable ids and compute accurate 'StateDelta's, no more.
data RunState = RunState
  { rsBudget  :: Int
  , rsMode    :: Mode
  , rsNext    :: Int          -- ^ monotonic counter for message\/tool ids
  , rsLastTC  :: Maybe (ToolCallId, MessageId)  -- ^ most recent tool call awaiting a result
  }

-- | The initial 'RunState' for a run seeded with the given budget and mode.
initRunState :: Int -> Mode -> RunState
initRunState b m = RunState b m 0 Nothing

-- | The current mode threaded through the state (read by tests and callers that
-- need to know whether a compaction has flipped the run into 'Summarising').
modeOf :: RunState -> Mode
modeOf = rsMode

-- | The running budget threaded through the state.
budgetOf :: RunState -> Int
budgetOf = rsBudget

-- | Mint a fresh, monotonic id with the given prefix and advance the counter.
mint :: Text -> RunState -> (Text, RunState)
mint prefix st = (prefix <> pack (show (rsNext st)), st { rsNext = rsNext st + 1 })

-- | A @STATE_DELTA@ replacing @/budget@ with the given remaining token count.
budgetDelta :: Int -> AgUiEvent
budgetDelta b = StateDelta [PatchReplace "/budget" (toJSON b)]

-- | Render a 'Mode' to its wire string.
modeText :: Mode -> Text
modeText Working = "working"
modeText Summarising = "summarising"

-- | The @RUN_STARTED@ + @STATE_SNAPSHOT@ emitted once at the top of a run: the
-- client's initial mirror of budget, mode, and the afforded tool names.
runStartEvents :: ThreadId -> RunId -> Int -> [ToolSpec] -> Mode -> [AgUiEvent]
runStartEvents t r b tools m =
  [ RunStarted t r
  , StateSnapshot (object
      [ "budget" .= b
      , "mode" .= modeText m
      , "tools" .= map (pack . specName) tools
      ])
  ]

-- | Events for a successful oracle 'Response': either a text message
-- (START\/CONTENT\/END) or a set of tool-call proposals (START\/ARGS\/END per
-- call), followed by the budget decrement from its 'Usage'. The @tcmsg-@ id
-- paired with each tool call is what the correlated 'worldEvents' result reuses.
oracleEvents :: Response -> RunState -> ([AgUiEvent], RunState)
oracleEvents r st0 =
  let spent = inTok (usage r) + outTok (usage r)
      st1   = st0 { rsBudget = rsBudget st0 - spent }
  in case calls r of
       [] ->
         let (mid, st2) = mint "msg-" st1
             evs = [ TextMessageStart mid "assistant"
                   , TextMessageContent mid (pack (say r))
                   , TextMessageEnd mid
                   , budgetDelta (rsBudget st2)
                   ]
         in (evs, st2)
       cs ->
         let step (acc, s) c =
               let (tid, s') = mint "tc-" s
                   trio = [ ToolCallStart tid (pack (tool c))
                          , ToolCallArgs tid (pack (args c))
                          , ToolCallEnd tid
                          ]
               in (acc ++ trio, s' { rsLastTC = Just (tid, "tcmsg-" <> tid) })
             (evs, st2) = foldl step ([], st1) cs
         in (evs ++ [budgetDelta (rsBudget st2)], st2)

-- | Events for a 'Refusal'. 'Overflow' is the compaction trigger: emit a custom
-- marker and flip mode to 'Summarising' (mirroring the coalgebra's own response
-- to overflow). 'Malformed' is surfaced as a @RUN_ERROR@ by the caller, so here
-- it produces none.
refusalEvents :: Refusal -> RunState -> ([AgUiEvent], RunState)
refusalEvents Overflow st =
  ( [ Custom "harness.compaction" (object ["reason" .= ("context overflow" :: Text)])
    , StateDelta [PatchReplace "/mode" (toJSON (modeText Summarising))]
    ]
  , st { rsMode = Summarising }
  )
refusalEvents (Malformed _) st = ([], st)

-- | The @TOOL_CALL_RESULT@ for a performed 'Call', correlated to the id minted
-- for the most recent tool-call proposal. If no proposal is outstanding there is
-- nothing to correlate, so it emits none.
worldEvents :: Obs -> RunState -> ([AgUiEvent], RunState)
worldEvents (Obs o) st = case rsLastTC st of
  Just (tid, mid) -> ([ToolCallResult mid tid (pack o)], st { rsLastTC = Nothing })
  Nothing         -> ([], st)

-- | The terminal @RUN_FINISHED@ for an 'Outcome', carrying a small result object
-- a client can render (status plus answer\/reason). Carries the @threadId@ as
-- well as the @runId@ because the AG-UI schema requires both on the terminal
-- event (a client that verifies events rejects the run otherwise).
runFinishEvents :: ThreadId -> RunId -> Outcome -> [AgUiEvent]
runFinishEvents t r o = [RunFinished t r (outcomeValue o)]

-- | The harness's own pure forecast as a @CUSTOM@ AG-UI event — the
-- differentiator primitive. Where the standard event stream reports what the run
-- /has/ done, this reports what 'Harness.Probe.assess' predicts it /will/ do:
-- how many steps ahead, whether it terminates, which irreversible tools it will
-- reach, and how many compactions it will provoke. Rides on @CUSTOM@ so it does
-- not widen the standard AG-UI event set.
forecastEvent :: Risk -> AgUiEvent
forecastEvent r = Custom "harness.forecast" (object
  [ "stepsAhead"   .= getSum (stepsAhead r)
  , "terminates"   .= getAny (terminates r)
  , "irreversible" .= irreversible r
  , "compactions"  .= getSum (compactions r)
  ])

-- | The JSON shape of an 'Outcome' embedded in @RUN_FINISHED@.
outcomeValue :: Outcome -> Value
outcomeValue = \case
  Done s    -> object ["status" .= ("done" :: Text), "answer" .= pack s]
  Exhausted -> object ["status" .= ("exhausted" :: Text)]
  Stuck s   -> object ["status" .= ("stuck" :: Text), "reason" .= pack s]
