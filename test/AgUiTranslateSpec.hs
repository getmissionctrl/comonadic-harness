module AgUiTranslateSpec (spec) where

import Test.Hspec
import qualified Data.Monoid
import Harness.Alphabet
import Harness.State (Mode (..))
import Harness.Probe (Risk (..))
import Harness.AgUi.Event
import Harness.AgUi.Translate

evType :: AgUiEvent -> String
evType = \case
  TextMessageStart{}   -> "TEXT_MESSAGE_START"
  TextMessageContent{} -> "TEXT_MESSAGE_CONTENT"
  TextMessageEnd{}     -> "TEXT_MESSAGE_END"
  ToolCallStart{}      -> "TOOL_CALL_START"
  ToolCallArgs{}       -> "TOOL_CALL_ARGS"
  ToolCallEnd{}        -> "TOOL_CALL_END"
  ToolCallResult{}     -> "TOOL_CALL_RESULT"
  StateDelta{}         -> "STATE_DELTA"
  Custom{}             -> "CUSTOM"
  _                    -> "OTHER"

resp :: String -> [Call] -> Response
resp s cs = Response s cs (Usage 10 5)

spec :: Spec
spec = describe "Harness.AgUi.Translate" $ do
  it "a plain text response emits START, CONTENT, END, then a budget STATE_DELTA" $ do
    let st0 = initRunState 1000 Working
        (evs, _) = oracleEvents (resp "hi there" []) st0
    map evType evs `shouldBe` ["TEXT_MESSAGE_START", "TEXT_MESSAGE_CONTENT", "TEXT_MESSAGE_END", "STATE_DELTA"]

  it "a tool-call response emits a START/ARGS/END proposal per call" $ do
    let st0 = initRunState 1000 Working
        (evs, _) = oracleEvents (resp "" [Call "read" "{\"path\":\"x\"}"]) st0
    map evType evs `shouldBe` ["TOOL_CALL_START", "TOOL_CALL_ARGS", "TOOL_CALL_END", "STATE_DELTA"]

  it "an Overflow refusal emits a compaction CUSTOM and a mode STATE_DELTA" $ do
    let st0 = initRunState 1000 Working
        (evs, st1) = refusalEvents Overflow st0
    map evType evs `shouldBe` ["CUSTOM", "STATE_DELTA"]
    modeOf st1 `shouldBe` Summarising

  it "worldEvents emits a TOOL_CALL_RESULT correlated to the last tool id" $ do
    let st0 = initRunState 1000 Working
        (_, st1) = oracleEvents (resp "" [Call "read" "{}"]) st0
        (evs, _) = worldEvents (Obs "file contents") st1
    map evType evs `shouldBe` ["TOOL_CALL_RESULT"]

  it "forecastEvent emits a CUSTOM harness.forecast with the risk fields" $ do
    let risk = Risk (Data.Monoid.Sum 5) (Data.Monoid.Any True) ["write"] (Data.Monoid.Sum 1)
    case forecastEvent risk of
      Custom name _ -> name `shouldBe` "harness.forecast"
      _             -> expectationFailure "expected a Custom event"
