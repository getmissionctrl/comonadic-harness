-- | The strict AG-UI event schema as a closed sum, with a hand-written 'ToJSON'
-- that emits exact wire shapes: a SCREAMING_SNAKE @type@ discriminator and
-- camelCase payload fields. Hand-written (not derived) because the wire format
-- is fixed by the AG-UI spec and because the harness build forbids partial
-- record selectors on a sum (@-Wall@ with no @DuplicateRecordFields@ would flag
-- them). The events are a /presentation/ artefact: nothing here touches the pure
-- coalgebra, and the discriminator lives in the instance, not in a field.
module Harness.AgUi.Event
  ( RunId
  , ThreadId
  , MessageId
  , ToolCallId
  , SubagentRunId
  , Patch (..)
  , AgUiEvent (..)
  ) where

import Data.Aeson (ToJSON (..), Value, object, (.=))
import Data.Text (Text)

-- | Identifier of a single run. A run is one drive of the coalgebra to a 'Halt';
-- the AG-UI @RUN_STARTED@/@RUN_FINISHED@ pair brackets it.
type RunId = Text

-- | Identifier of the conversation thread a run belongs to. v1 uses the run id
-- for both, but the distinction is kept because AG-UI clients key on it.
type ThreadId = Text

-- | Identifier of one assistant text message, stable across its
-- START\/CONTENT*\/END frames so a client can accumulate the streamed deltas.
type MessageId = Text

-- | Identifier of one tool-call proposal, stable across its START\/ARGS*\/END
-- frames and reused by the correlated @TOOL_CALL_RESULT@.
type ToolCallId = Text

-- | Identifier of one subagent run nested under a parent run. Stable across its
-- @SUBAGENT_STARTED@\/@SUBAGENT_FINISHED@ frames so a client can group them.
type SubagentRunId = Text

-- | One RFC-6902 JSON Patch operation — the only two ops v1 emits. Carried in a
-- @STATE_DELTA@ so a client can mutate its mirror of the harness state
-- (@/budget@, @/mode@) without a full snapshot.
data Patch
  = PatchReplace Text Value  -- ^ @{"op":"replace","path":p,"value":v}@
  | PatchAdd Text Value      -- ^ @{"op":"add","path":p,"value":v}@
  deriving stock (Eq, Show)

instance ToJSON Patch where
  toJSON (PatchReplace p v) = object ["op" .= ("replace" :: Text), "path" .= p, "value" .= v]
  toJSON (PatchAdd p v)     = object ["op" .= ("add" :: Text), "path" .= p, "value" .= v]

-- | The closed set of AG-UI events v1 emits. Fields are positional to avoid
-- partial record selectors on a sum; the wire field names live entirely in the
-- 'ToJSON' instance. @CUSTOM@ is the extension point: the harness's own
-- @harness.forecast@ and @harness.compaction@ signals ride on it rather than
-- widening the standard event set.
data AgUiEvent
  = RunStarted ThreadId RunId
  | RunFinished ThreadId RunId Value     -- ^ threadId, runId, result payload
  | RunError Text                        -- ^ message
  | StepStarted Text                     -- ^ stepName
  | StepFinished Text                    -- ^ stepName
  | TextMessageStart MessageId Text      -- ^ messageId, role
  | TextMessageContent MessageId Text    -- ^ messageId, delta
  | TextMessageEnd MessageId
  | ToolCallStart ToolCallId Text        -- ^ toolCallId, toolCallName
  | ToolCallArgs ToolCallId Text         -- ^ toolCallId, delta (raw args)
  | ToolCallEnd ToolCallId
  | ToolCallResult MessageId ToolCallId Text  -- ^ messageId, toolCallId, content
  | StateSnapshot Value                  -- ^ full snapshot object
  | StateDelta [Patch]                   -- ^ RFC-6902 patch array
  | Custom Text Value                    -- ^ name, value
  | SubagentStarted SubagentRunId Text (Maybe Text)  -- ^ subagentRunId, name, parentToolCallId?
  | SubagentFinished SubagentRunId Value             -- ^ subagentRunId, result
  | SubagentError SubagentRunId Text                 -- ^ subagentRunId, message
  | ActivitySnapshot MessageId Text Value            -- ^ id, activityType, content
  | ActivityDelta MessageId Text [Patch]             -- ^ id, activityType, patch
  deriving stock (Eq, Show)

instance ToJSON AgUiEvent where
  toJSON = \case
    RunStarted t r         -> object ["type" .= ("RUN_STARTED" :: Text), "threadId" .= t, "runId" .= r]
    RunFinished t r res    -> object ["type" .= ("RUN_FINISHED" :: Text), "threadId" .= t, "runId" .= r, "result" .= res]
    RunError m             -> object ["type" .= ("RUN_ERROR" :: Text), "message" .= m]
    StepStarted n          -> object ["type" .= ("STEP_STARTED" :: Text), "stepName" .= n]
    StepFinished n         -> object ["type" .= ("STEP_FINISHED" :: Text), "stepName" .= n]
    TextMessageStart m r   -> object ["type" .= ("TEXT_MESSAGE_START" :: Text), "messageId" .= m, "role" .= r]
    TextMessageContent m d -> object ["type" .= ("TEXT_MESSAGE_CONTENT" :: Text), "messageId" .= m, "delta" .= d]
    TextMessageEnd m       -> object ["type" .= ("TEXT_MESSAGE_END" :: Text), "messageId" .= m]
    ToolCallStart c n      -> object ["type" .= ("TOOL_CALL_START" :: Text), "toolCallId" .= c, "toolCallName" .= n]
    ToolCallArgs c d       -> object ["type" .= ("TOOL_CALL_ARGS" :: Text), "toolCallId" .= c, "delta" .= d]
    ToolCallEnd c          -> object ["type" .= ("TOOL_CALL_END" :: Text), "toolCallId" .= c]
    ToolCallResult m c ct  -> object ["type" .= ("TOOL_CALL_RESULT" :: Text), "messageId" .= m, "toolCallId" .= c, "content" .= ct]
    StateSnapshot s        -> object ["type" .= ("STATE_SNAPSHOT" :: Text), "snapshot" .= s]
    StateDelta ps          -> object ["type" .= ("STATE_DELTA" :: Text), "delta" .= ps]
    Custom n v             -> object ["type" .= ("CUSTOM" :: Text), "name" .= n, "value" .= v]
    SubagentStarted s n p  -> object $ ["type" .= ("SUBAGENT_STARTED" :: Text), "subagentRunId" .= s, "name" .= n]
                                        ++ maybe [] (\x -> ["parentToolCallId" .= x]) p
    SubagentFinished s r   -> object ["type" .= ("SUBAGENT_FINISHED" :: Text), "subagentRunId" .= s, "result" .= r]
    SubagentError s m      -> object ["type" .= ("SUBAGENT_ERROR" :: Text), "subagentRunId" .= s, "message" .= m]
    ActivitySnapshot i a c -> object ["type" .= ("ACTIVITY_SNAPSHOT" :: Text), "messageId" .= i, "activityType" .= a, "content" .= c]
    ActivityDelta i a ps   -> object ["type" .= ("ACTIVITY_DELTA" :: Text), "messageId" .= i, "activityType" .= a, "patch" .= ps]
