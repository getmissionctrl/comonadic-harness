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

  it "GET /runs/{id}/events streams a RUN_STARTED frame" $
    testWithApplication (mkApp fakeProviderFactory) $ \port -> do
      mgr <- newManager defaultManagerSettings
      -- the first run on a fresh app is deterministically "run-0"
      req <- startRun port "{\"task\":\"hi\"}"
      _ <- httpLbs req mgr
      evReq <- parseRequest ("http://localhost:" ++ show port ++ "/runs/run-0/events")
      chunk <- withResponse evReq mgr $ \r -> brRead (responseBody r)
      BS.unpack chunk `shouldContain` "RUN_STARTED"
