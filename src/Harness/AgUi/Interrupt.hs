-- | Interrupt outcomes ride inside a @RUN_FINISHED@ event's result 'Value' rather
-- than a dedicated constructor: a run segment that halts awaiting a human decision
-- finishes with @result = { "type": "interrupt", "interrupts": [ … ] }@. These are
-- the minimal builders for that payload; the richer per-interrupt record (options,
-- assessment, …) is supplied by the caller (the RecipeF side) as the @message@ /
-- @responseSchema@ fields.
module Harness.AgUi.Interrupt
  ( interruptOutcome
  , mkInterrupt
  ) where

import Data.Aeson (Value, object, (.=))
import Data.Text (Text)

-- | The @RUN_FINISHED@ result payload for a segment that halted on interrupts.
interruptOutcome :: [Value] -> Value
interruptOutcome is = object ["type" .= ("interrupt" :: Text), "interrupts" .= is]

-- | One interrupt descriptor: a stable id, a machine reason, an optional
-- responseSchema (e.g. an enum of the decision's options) and an optional
-- human-facing message.
mkInterrupt :: Text -> Text -> Maybe Value -> Maybe Text -> Value
mkInterrupt ident reason schema message = object $
  ["id" .= ident, "reason" .= reason]
    ++ maybe [] (\s -> ["responseSchema" .= s]) schema
    ++ maybe [] (\m -> ["message" .= m]) message
