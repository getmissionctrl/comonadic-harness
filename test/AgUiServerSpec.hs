module AgUiServerSpec (spec) where

import Test.Hspec
import Network.Wai.Handler.Warp (testWithApplication)
import Network.HTTP.Client
import Network.HTTP.Types.Status (statusIsSuccessful)
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as BL
import Harness.AgUi.Server

-- Build a POST /runs request for the given body against the given port.
startRun :: Int -> BL.ByteString -> IO Request
startRun port body = do
  req0 <- parseRequest ("POST http://localhost:" ++ show port ++ "/runs")
  pure req0 { requestBody = RequestBodyLBS body
            , requestHeaders = [("Content-Type", "application/json")] }

spec :: Spec
spec = describe "Harness.AgUi.Server" $ do
  it "POST /runs returns a runId" $
    testWithApplication (mkApp fakeProviderFactory) $ \port -> do
      mgr <- newManager defaultManagerSettings
      req <- startRun port "{\"task\":\"hi\"}"
      resp <- httpLbs req mgr
      responseStatus resp `shouldSatisfy` statusIsSuccessful
      BL.unpack (responseBody resp) `shouldContain` "runId"

  it "POST /agent (RunAgentInput) streams a full run and closes on RUN_FINISHED" $
    testWithApplication (mkApp fakeProviderFactory) $ \port -> do
      mgr <- newManager defaultManagerSettings
      req0 <- parseRequest ("POST http://localhost:" ++ show port ++ "/agent")
      let req = req0
            { requestBody = RequestBodyLBS
                "{\"threadId\":\"t-1\",\"runId\":\"r-1\",\"messages\":[{\"id\":\"m1\",\"role\":\"user\",\"content\":\"hi\"}]}"
            , requestHeaders = [("Content-Type", "application/json"), ("Accept", "text/event-stream")]
            }
      -- httpLbs reads the SSE body to completion; the endpoint closes it on RUN_FINISHED
      resp <- httpLbs req mgr
      let body = BL.unpack (responseBody resp)
      body `shouldContain` "RUN_STARTED"
      body `shouldContain` "RUN_FINISHED"
      body `shouldContain` "\"runId\":\"r-1\""
      -- AG-UI requires threadId on RUN_STARTED and RUN_FINISHED; a verifying
      -- client (assistant-ui) rejects the run without it
      body `shouldContain` "\"threadId\":\"t-1\""

  it "GET /runs/{id}/events streams a RUN_STARTED frame" $
    testWithApplication (mkApp fakeProviderFactory) $ \port -> do
      mgr <- newManager defaultManagerSettings
      -- the first run on a fresh app is deterministically "run-0"
      req <- startRun port "{\"task\":\"hi\"}"
      _ <- httpLbs req mgr
      evReq <- parseRequest ("http://localhost:" ++ show port ++ "/runs/run-0/events")
      chunk <- withResponse evReq mgr $ \r -> brRead (responseBody r)
      BS.unpack chunk `shouldContain` "RUN_STARTED"
