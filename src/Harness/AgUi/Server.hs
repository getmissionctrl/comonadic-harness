{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

-- | The AG-UI transport: a Servant JSON API for starting runs and posting input,
-- plus a WAI SSE endpoint for the live event stream. Holds a registry of
-- in-flight runs; each run walks on its own thread against the tracing decorator
-- ('Harness.AgUi.Sink.traceEnv'), writing to an in-memory 'EventLog' (for SSE
-- replay + live follow).
--
-- The provider factory is injected ('ProviderFactory') so tests supply a
-- deterministic fake and production supplies a live Ollama env — the same
-- dependency-inversion the pure core uses for its 'Env' seam. Nothing here
-- touches the coalgebra: the server drives 'Harness.Run.run' over the standard
-- 'harness' unfold and only decorates the seams.
module Harness.AgUi.Server
  ( ProviderFactory
  , mkApp
  , serve'
  , fakeProviderFactory
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.STM
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.:?), (.!=), (.=), encode)
import qualified Data.ByteString.Builder as BB
import qualified Data.Map.Strict as Map
import Data.Text (Text, pack, unpack)
import Network.HTTP.Types (status200, status404)
import qualified Network.Wai as Wai
import qualified Network.Wai.Handler.Warp as Warp
import Servant

import Harness.Alphabet
import Harness.State (S (..), Mode (..), Turn (..))
import Harness.Coalgebra (harness)
import Harness.Run (Env (..), run)
import Harness.AgUi.Event
import Harness.AgUi.Sink
import Harness.AgUi.Translate (RunState, initRunState, runStartEvents, runFinishEvents)
import Harness.AgUi.HumanEnv

-- | Build the per-run behaviour 'Env' (provider + world) for a run id. Injected
-- so tests supply a fake and production supplies Ollama + sandbox tools; the
-- transport is oblivious to which.
type ProviderFactory = RunId -> IO (Env IO)

-- | Everything the transport needs to reach a live run: its event log (for SSE),
-- its input slot (for the human oracle), and the threaded 'RunState' the tracing
-- decorator mutates.
data RunHandle = RunHandle
  { rhLog   :: EventLog
  , rhSlot  :: InputSlot
  , rhState :: TVar RunState
  }

-- | The set of live runs, keyed by run id.
newtype Registry = Registry (TVar (Map.Map RunId RunHandle))

-- | Request body of @POST /runs@: the seed task, and an optional drive mode
-- (@"auto"@ — the provider answers every turn; @"human"@ — a person answers via
-- @POST /runs/{id}/input@). Defaults to @"auto"@.
data StartReq = StartReq
  { task    :: Text
  , runMode :: Text
  }

instance FromJSON StartReq where
  parseJSON = withObject "StartReq" $ \o ->
    StartReq <$> o .: "task" <*> (o .:? "mode" .!= "auto")

-- | Response body of @POST /runs@: the minted run id, echoed as the thread id.
newtype StartResp = StartResp RunId
instance ToJSON StartResp where
  toJSON (StartResp r) = object ["runId" .= r, "threadId" .= r]

-- | Request body of @POST /runs/{id}/input@: a plain-text answer for the oracle.
newtype InputReq = InputReq Text
instance FromJSON InputReq where
  parseJSON = withObject "InputReq" $ \o -> InputReq <$> o .: "text"

-- | The typed JSON surface. The SSE stream is deliberately /not/ a Servant route
-- (it is routed raw, below) so the exact @data: {json}\\n\\n@ framing stays under
-- our control rather than a streaming combinator's.
type JsonApi =
       "runs" :> ReqBody '[JSON] StartReq :> Post '[JSON] StartResp
  :<|> "runs" :> Capture "id" Text :> "input" :> ReqBody '[JSON] InputReq :> Post '[JSON] NoContent

jsonApi :: Proxy JsonApi
jsonApi = Proxy

-- | Build the full WAI application: the Servant JSON API, with @GET
-- /runs/{id}/events@ intercepted and routed to the raw SSE handler.
mkApp :: ProviderFactory -> IO Wai.Application
mkApp factory = do
  reg <- Registry <$> newTVarIO Map.empty
  let jsonApp = serve jsonApi (startH factory reg :<|> inputH reg)
  pure (router reg jsonApp)

-- | Route @GET /runs/{id}/events@ to the SSE handler; everything else to Servant.
router :: Registry -> Wai.Application -> Wai.Application
router reg jsonApp req respond =
  case (Wai.requestMethod req, Wai.pathInfo req) of
    ("GET", ["runs", rid, "events"]) -> sseH reg rid req respond
    _                                -> jsonApp req respond

-- | @POST /runs@: mint an id, register the run, spawn its thread, return the id.
-- The thread emits @RUN_STARTED@ + snapshot, drives the run through the tracing
-- decorator, then emits @RUN_FINISHED@.
startH :: ProviderFactory -> Registry -> StartReq -> Handler StartResp
startH factory (Registry regv) sr = liftIO $ do
  logv <- newEventLog
  slot <- newInputSlot
  let seeded = S { transcript = [Summary (unpack (task sr))]
                 , pending = [], budget = 1200, mode = Working, tools = [] }
  stv <- newTVarIO (initRunState (budget seeded) (mode seeded))
  rid <- atomically $ do
    m <- readTVar regv
    let rid = pack ("run-" <> show (Map.size m))
    writeTVar regv (Map.insert rid (RunHandle logv slot stv) m)
    pure rid
  inner <- factory rid
  let sink = logSink logv
      -- One clear wiring, selected by the drive mode. Auto: the provider answers
      -- every turn. Human: the oracle blocks on the input slot; the provider's
      -- world seam still performs tools automatically.
      env = case runMode sr of
        "human" -> traceEnv sink stv (humanEnv (\_ -> pure ()) slot (world inner))
        _       -> traceEnv sink stv inner
  void $ forkIO $ do
    mapM_ sink (runStartEvents rid rid (budget seeded) (tools seeded) (mode seeded))
    o <- run env (harness seeded)
    mapM_ sink (runFinishEvents rid o)
  pure (StartResp rid)

-- | @POST /runs/{id}/input@: fill the run's input slot with a text 'Response',
-- unblocking a human-driven oracle. 404 if the run id is unknown.
inputH :: Registry -> Text -> InputReq -> Handler NoContent
inputH (Registry regv) rid (InputReq t) = do
  m <- liftIO (readTVarIO regv)
  case Map.lookup rid m of
    Nothing -> throwError err404
    Just h  -> do
      liftIO $ atomically $ provideInput (rhSlot h)
        (Right (Response (unpack t) [] (Usage 0 0)))
      pure NoContent

-- | @GET /runs/{id}/events@: SSE. Replay the log from the start, then follow it
-- live — 'readFrom' blocks until new events arrive, so the same loop serves both
-- replay and live tail. The stream stays open until the client disconnects.
sseH :: Registry -> Text -> Wai.Application
sseH (Registry regv) rid _req respond = do
  m <- readTVarIO regv
  case Map.lookup rid m of
    Nothing -> respond (Wai.responseLBS status404 [] "no such run")
    Just h  -> respond $ Wai.responseStream status200 hdrs $ \write flush -> do
      let loop cursor = do
            (evs, cursor') <- atomically (readFrom (rhLog h) cursor)
            mapM_ (\e -> write (frame e) >> flush) evs
            loop cursor'
      loop 0
  where
    hdrs = [ ("Content-Type", "text/event-stream")
           , ("Cache-Control", "no-cache")
           , ("Connection", "keep-alive")
           ]
    frame e = BB.byteString "data: " <> BB.lazyByteString (encode e) <> BB.byteString "\n\n"

-- | Run the app on a port (production entry uses this).
serve' :: Int -> ProviderFactory -> IO ()
serve' port factory = mkApp factory >>= Warp.run port

-- | A deterministic fake provider for tests: answers once with a text response
-- carrying no tool calls, which the coalgebra reads as completion.
fakeProviderFactory :: ProviderFactory
fakeProviderFactory _ = pure Env
  { oracle = \_ -> pure (Right (Response "hi" [] (Usage 1 1)))
  , world  = \_ -> pure (Obs "")
  }
