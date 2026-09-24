module AgUiEventSpec (spec) where

import Test.Hspec
import qualified Data.Aeson
import Data.Aeson (encode, object, (.=), Value)
import Harness.AgUi.Event

-- Decode our encoded event back to a generic Value for order-insensitive comparison.
enc :: AgUiEvent -> Value
enc e = case Data.Aeson.decode (encode e) of
  Just v  -> v
  Nothing -> error "re-decode failed"

spec :: Spec
spec = describe "Harness.AgUi.Event ToJSON wire shapes" $ do
  it "RunStarted uses SCREAMING_SNAKE type and camelCase ids" $
    enc (RunStarted "thread-1" "run-1")
      `shouldBe` object ["type" .= ("RUN_STARTED" :: String), "threadId" .= ("thread-1" :: String), "runId" .= ("run-1" :: String)]

  it "TextMessageContent carries messageId and delta" $
    enc (TextMessageContent "msg-1" "hello")
      `shouldBe` object ["type" .= ("TEXT_MESSAGE_CONTENT" :: String), "messageId" .= ("msg-1" :: String), "delta" .= ("hello" :: String)]

  it "ToolCallStart carries toolCallId and toolCallName" $
    enc (ToolCallStart "tc-1" "read")
      `shouldBe` object ["type" .= ("TOOL_CALL_START" :: String), "toolCallId" .= ("tc-1" :: String), "toolCallName" .= ("read" :: String)]

  it "RunFinished carries threadId and runId (AG-UI requires both on the terminal event)" $
    enc (RunFinished "thread-1" "run-1" (Data.Aeson.object ["status" .= ("done" :: String)]))
      `shouldBe` object
        [ "type" .= ("RUN_FINISHED" :: String)
        , "threadId" .= ("thread-1" :: String)
        , "runId" .= ("run-1" :: String)
        , "result" .= object ["status" .= ("done" :: String)]
        ]

  it "StateDelta carries an RFC-6902 patch array under delta" $
    enc (StateDelta [PatchReplace "/budget" (Data.Aeson.toJSON (900 :: Int))])
      `shouldBe` object ["type" .= ("STATE_DELTA" :: String), "delta" .= [object ["op" .= ("replace" :: String), "path" .= ("/budget" :: String), "value" .= (900 :: Int)]]]

  it "SubagentStarted uses SUBAGENT_STARTED + subagentRunId/name" $
    enc (SubagentStarted "sa-1" "laya:qualify" Nothing)
      `shouldBe` object ["type" .= ("SUBAGENT_STARTED"::String), "subagentRunId" .= ("sa-1"::String), "name" .= ("laya:qualify"::String)]

  it "ActivitySnapshot uses ACTIVITY_SNAPSHOT + activityType + content" $
    enc (ActivitySnapshot "act-1" "DECISION" (object ["chose" .= ("Win"::String)]))
      `shouldBe` object ["type" .= ("ACTIVITY_SNAPSHOT"::String), "messageId" .= ("act-1"::String), "activityType" .= ("DECISION"::String), "content" .= object ["chose" .= ("Win"::String)]]

  it "ReasoningMessageStart uses REASONING_MESSAGE_START + messageId + reasoning role" $
    enc (ReasoningMessageStart "rsn-1")
      `shouldBe` object ["type" .= ("REASONING_MESSAGE_START"::String), "messageId" .= ("rsn-1"::String), "role" .= ("reasoning"::String)]

  it "ReasoningMessageContent uses REASONING_MESSAGE_CONTENT + messageId + delta" $
    enc (ReasoningMessageContent "rsn-1" "let me think")
      `shouldBe` object ["type" .= ("REASONING_MESSAGE_CONTENT"::String), "messageId" .= ("rsn-1"::String), "delta" .= ("let me think"::String)]
