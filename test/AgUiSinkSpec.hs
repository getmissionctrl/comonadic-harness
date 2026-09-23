module AgUiSinkSpec (spec) where

import Test.Hspec
import Control.Concurrent.STM
import Harness.Alphabet
import Harness.State (Mode (..))
import Harness.Run (Env (..))
import Harness.AgUi.Event
import Harness.AgUi.Sink

evType :: AgUiEvent -> String
evType = \case
  TextMessageStart{}   -> "TEXT_MESSAGE_START"
  TextMessageContent{} -> "TEXT_MESSAGE_CONTENT"
  TextMessageEnd{}     -> "TEXT_MESSAGE_END"
  ToolCallResult{}     -> "TOOL_CALL_RESULT"
  StateDelta{}         -> "STATE_DELTA"
  _                    -> "OTHER"

spec :: Spec
spec = describe "Harness.AgUi.Sink tracing decorator" $
  it "wraps an inner Env and emits AG-UI events for oracle and world calls" $ do
    log' <- newTVarIO []
    let sink e = atomically (modifyTVar' log' (++ [e]))
        inner = Env
          { oracle = \_ -> pure (Right (Response "answer" [] (Usage 1 1)))
          , world  = \_ -> pure (Obs "obs")
          }
    st <- newTVarIO (initRunState 100 Working)
    let traced = traceEnv sink st inner
    _ <- oracle traced (Request (Prompt "p") [] [])
    _ <- world traced (Call "read" "{}")
    got <- readTVarIO log'
    map evType got `shouldContain` ["TEXT_MESSAGE_START"]
