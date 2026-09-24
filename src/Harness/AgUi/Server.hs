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
  , EnvBuilder
  , ServeConfig (..)
  , defaultServeConfig
  , mkApp
  , mkAppWith
  , serve'
  , serveWith
  , fakeProviderFactory
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.STM
import Control.Monad (void, when)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), eitherDecode, object, withObject, (.:), (.:?), (.!=), (.=), encode)
import qualified Data.ByteString.Builder as BB
import qualified Data.Map.Strict as Map
import Data.Text (Text, pack, unpack)
import Network.HTTP.Types (status200, status204, status400, status404)
import qualified Network.HTTP.Types.Header as H
import qualified Network.Wai as Wai
import qualified Network.Wai.Handler.Warp as Warp
import Servant hiding (respond)

import Harness.Alphabet
import Harness.State (S (..), Mode (..), Turn (..))
import Harness.Coalgebra (harness)
import Harness.Path (Hypo (..))
import Harness.Probe (assess)
import Harness.Run (Env (..), run)
import Harness.AgUi.Event
import Harness.AgUi.Sink
import Harness.AgUi.Translate (RunState, runStartEvents, runFinishEvents, forecastEvent)
import Harness.AgUi.HumanEnv

-- | Build the per-run behaviour 'Env' (provider + world) for a run id. Injected
-- so tests supply a fake and production supplies Ollama + sandbox tools; the
-- transport is oblivious to which.
type ProviderFactory = RunId -> IO (Env IO)

-- | Build a run's 'Env' given its event 'Sink' and threaded 'RunState'. Unlike a
-- 'ProviderFactory' (which the tracing decorator wraps to derive events /after/
-- each turn), an 'EnvBuilder' is handed the sink directly, so it can emit events
-- __during__ a turn — this is what token streaming needs: the oracle pushes
-- @TEXT_MESSAGE_CONTENT@ deltas as the model produces them. A builder owns all
-- emission for its runs (the server does not also wrap it with 'traceEnv').
type EnvBuilder = Sink -> TVar RunState -> RunId -> IO (Env IO)

-- | How the server seeds and drives each run: the provider 'ProviderFactory',
-- the tools every run is afforded ('scfTools' — empty for the fake, the real
-- read\/write\/bash\/commit\/scrape_url set for a live agent), the starting
-- token 'scfBudget', and an optional streaming 'EnvBuilder'. When 'scfEnvBuilder'
-- is 'Just', it owns emission (used for the live, token-streaming agent); when
-- 'Nothing', runs use 'scfFactory' wrapped in the tracing decorator (the fake and
-- the tests).
data ServeConfig = ServeConfig
  { scfFactory    :: ProviderFactory
  , scfTools      :: [ToolSpec]
  , scfBudget     :: Int
  , scfEnvBuilder :: Maybe EnvBuilder
  }

-- | A config for the deterministic fake: no tools, a small budget, no streaming
-- builder. Matches the pre-config behaviour so existing callers
-- ('mkApp'\/'serve'') are unchanged.
defaultServeConfig :: ProviderFactory -> ServeConfig
defaultServeConfig f = ServeConfig f [] 1200 Nothing

-- | Everything the transport needs to reach a live run: its event log (for SSE)
-- and its input slot (for a human-driven oracle). The threaded @RunState@ that
-- the tracing decorator mutates is a private @TVar@ closed over by the run
-- thread, not stored here — nothing outside the run reads it.
data RunHandle = RunHandle
  { rhLog  :: EventLog
  , rhSlot :: InputSlot
  }

-- | The set of live runs, keyed by run id.
newtype Registry = Registry (TVar (Map.Map RunId RunHandle))

-- | Request body of @POST /runs@: the seed task, and an optional drive mode
-- (@"auto"@ — the provider answers every turn; @"human"@ — a person answers via
-- @POST /runs/{id}/input@). Defaults to @"auto"@.
data StartReq = StartReq
  { task     :: Text
  , runMode  :: Text
  , forecast :: Bool
  }

instance FromJSON StartReq where
  parseJSON = withObject "StartReq" $ \o ->
    StartReq <$> o .: "task" <*> (o .:? "mode" .!= "auto") <*> (o .:? "forecast" .!= False)

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

-- | Build the full WAI application. Three raw routes are intercepted before
-- Servant: @GET /runs/{id}/events@ (our own two-step SSE), and the standard
-- AG-UI @POST /agent@ (single-POST-SSE, what an off-the-shelf AG-UI client
-- speaks) with its @OPTIONS@ CORS preflight. Everything else is the Servant
-- JSON API.
mkApp :: ProviderFactory -> IO Wai.Application
mkApp = mkAppWith . defaultServeConfig

-- | Build the WAI application from a full 'ServeConfig' (tools + budget + factory).
mkAppWith :: ServeConfig -> IO Wai.Application
mkAppWith cfg = do
  reg <- Registry <$> newTVarIO Map.empty
  let jsonApp = serve jsonApi (startH cfg reg :<|> inputH reg)
  pure (router cfg reg jsonApp)

-- | Route the raw endpoints; delegate the rest to Servant.
router :: ServeConfig -> Registry -> Wai.Application -> Wai.Application
router cfg reg jsonApp req respond =
  case (Wai.requestMethod req, Wai.pathInfo req) of
    ("GET",     ["runs", rid, "events"]) -> sseH reg rid req respond
    ("POST",    ["agent"])               -> aguiH cfg reg req respond
    ("OPTIONS", ["agent"])               -> respond (Wai.responseLBS status204 preflightHeaders "")
    _                                    -> jsonApp req respond

-- | Permissive CORS. The smoke-test frontend is served from a different origin
-- (the Vite dev server), so the browser preflights @POST /agent@ and expects an
-- @Access-Control-Allow-Origin@ on the response. v1 allows any origin — this is
-- a local demo transport, not an authenticated surface.
allowOrigin :: H.Header
allowOrigin = ("Access-Control-Allow-Origin", "*")

-- | Headers answering the CORS preflight for @POST /agent@.
preflightHeaders :: H.ResponseHeaders
preflightHeaders =
  [ allowOrigin
  , ("Access-Control-Allow-Methods", "POST, OPTIONS")
  , ("Access-Control-Allow-Headers", "Content-Type")
  ]

-- | @POST /runs@: mint an id, register the run, spawn its thread, return the id.
-- The thread emits @RUN_STARTED@ + snapshot, drives the run through the tracing
-- decorator, then emits @RUN_FINISHED@.
startH :: ServeConfig -> Registry -> StartReq -> Handler StartResp
startH cfg (Registry regv) sr = liftIO $ do
  logv <- newEventLog
  slot <- newInputSlot
  let seeded = S { transcript = [Summary (unpack (task sr))]
                 , pending = [], budget = scfBudget cfg, mode = Working, tools = scfTools cfg }
  stv <- newTVarIO (initRunState (budget seeded) (mode seeded))
  rid <- atomically $ do
    m <- readTVar regv
    let rid = pack ("run-" <> show (Map.size m))
    writeTVar regv (Map.insert rid (RunHandle logv slot) m)
    pure rid
  let sink = logSink logv
  -- A streaming env builder (if configured) owns all emission (token streaming);
  -- otherwise wrap the plain provider with the tracing decorator, selecting the
  -- drive mode. Auto: the provider answers every turn. Human: the oracle blocks
  -- on the input slot; the provider's world seam still performs tools.
  env <- case scfEnvBuilder cfg of
    Just build -> build sink stv rid
    Nothing -> do
      inner <- scfFactory cfg rid
      pure $ case runMode sr of
        "human" -> traceEnv sink stv (humanEnv (\_ -> pure ()) slot (world inner))
        _       -> traceEnv sink stv inner
  void $ forkIO $ do
    mapM_ sink (runStartEvents rid rid (budget seeded) (tools seeded) (mode seeded))
    -- Opt-in: emit the harness's own pure forecast for this run's seed before a
    -- single token is spent. Off by default; the client asks with "forecast":true.
    when (forecast sr) $ sink (forecastEvent (assess defaultHypo 40 (harness seeded)))
    o <- run env (harness seeded)
    mapM_ sink (runFinishEvents rid rid o)
  pure (StartResp rid)

-- | A crude pure stand-in for the oracle\/world used only to compute the opt-in
-- @harness.forecast@ at run start. It mirrors the demo's @hypo@ (@app/Main.hs@):
-- summarise when offered no tools, overflow once the prompt grows past a few
-- lines, otherwise propose a @write@. It is deliberately crude — the forecast is
-- only ever as good as the 'Hypo' (BRIEF §5), and a better model of the oracle
-- is a separate, harder problem.
defaultHypo :: Hypo
defaultHypo = Hypo
  { guessOracle = \(Request (Prompt p) ts _) ->
      if null ts
        then Right (Response "summary" [] (Usage 300 20))
        else if length (lines p) >= 5
               then Left Overflow
               else Right (Response "guess" [Call "write" "g.txt"] (Usage 120 40))
  , guessWorld = \c -> Obs (tool c)
  }

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

-- | The subset of a standard AG-UI @RunAgentInput@ this server reads: the
-- client-minted @threadId@\/@runId@ (echoed back so the client's event
-- verification correlates), and the seed task extracted from the message
-- history. The harness seeds a fresh run from a task rather than replaying a
-- message list, so v1 takes the latest user message as the task and ignores the
-- rest; @tools@\/@context@\/@state@ are accepted and dropped. [design]
data RunAgentInput = RunAgentInput Text Text Text  -- threadId, runId, task

instance FromJSON RunAgentInput where
  parseJSON = withObject "RunAgentInput" $ \o -> do
    tid  <- o .:? "threadId" .!= "thread-0"
    rid  <- o .:? "runId" .!= "run-0"
    msgs <- o .:? "messages" .!= []
    pure (RunAgentInput tid rid (lastUserText msgs))

-- | One AG-UI message, reduced to role + text content. Content that is not a
-- plain string (multi-part content) collapses to empty — enough for the smoke
-- test, which sends plain user text.
data Msg = Msg Text Text

instance FromJSON Msg where
  parseJSON = withObject "Msg" $ \o -> do
    role <- o .:? "role" .!= ""
    c    <- o .:? "content"
    pure (Msg role (contentText c))

-- | Extract plain-text content, or empty for absent\/structured content.
contentText :: Maybe Value -> Text
contentText (Just (String t)) = t
contentText _                 = ""

-- | The content of the last @user@ message, or empty if there is none.
lastUserText :: [Msg] -> Text
lastUserText = foldl (\acc (Msg role content) -> if role == "user" then content else acc) ""

-- | @POST /agent@: the standard AG-UI HTTP transport. Accepts a @RunAgentInput@,
-- starts a run, and streams the AG-UI events back __on this same response__ as
-- @text/event-stream@ (unlike our two-step @POST /runs@ + @GET events@ pair).
-- This is the shape an off-the-shelf AG-UI client (assistant-ui, CopilotKit,
-- the @\@ag-ui/client@ @HttpAgent@) speaks. The stream closes on @RUN_FINISHED@.
aguiH :: ServeConfig -> Registry -> Wai.Application
aguiH cfg (Registry regv) req respond = do
  body <- Wai.strictRequestBody req
  case eitherDecode body of
    Left _ -> respond (Wai.responseLBS status400 [allowOrigin, jsonCT] "{\"error\":\"bad RunAgentInput\"}")
    Right (RunAgentInput tid rid task') -> do
      logv <- newEventLog
      slot <- newInputSlot
      let seeded = S { transcript = [Summary (unpack task')]
                     , pending = [], budget = scfBudget cfg, mode = Working, tools = scfTools cfg }
      stv <- newTVarIO (initRunState (budget seeded) (mode seeded))
      atomically (modifyTVar' regv (Map.insert rid (RunHandle logv slot)))
      let sink = logSink logv
      env <- case scfEnvBuilder cfg of
        Just build -> build sink stv rid
        Nothing    -> traceEnv sink stv <$> scfFactory cfg rid
      void $ forkIO $ do
        mapM_ sink (runStartEvents tid rid (budget seeded) (tools seeded) (mode seeded))
        o <- run env (harness seeded)
        mapM_ sink (runFinishEvents tid rid o)
      respond $ Wai.responseStream status200 [allowOrigin, sseCT, noCache] $ \write flush -> do
        let loop cursor = do
              (evs, cursor') <- atomically (readFrom logv cursor)
              mapM_ (\e -> write (frame e) >> flush) evs
              -- close the stream once the terminal event has been sent
              if any isFinished evs then pure () else loop cursor'
        loop 0
  where
    jsonCT  = ("Content-Type", "application/json")
    sseCT   = ("Content-Type", "text/event-stream")
    noCache = ("Cache-Control", "no-cache")
    frame e = BB.byteString "data: " <> BB.lazyByteString (encode e) <> BB.byteString "\n\n"
    isFinished RunFinished{} = True
    isFinished _             = False

-- | Run the fake-config app on a port.
serve' :: Int -> ProviderFactory -> IO ()
serve' port factory = serveWith port (defaultServeConfig factory)

-- | Run the app on a port with a full 'ServeConfig' (production entry uses this).
serveWith :: Int -> ServeConfig -> IO ()
serveWith port cfg = mkAppWith cfg >>= Warp.run port

-- | A deterministic fake provider for tests: answers once with a text response
-- carrying no tool calls, which the coalgebra reads as completion.
fakeProviderFactory :: ProviderFactory
fakeProviderFactory _ = pure Env
  { oracle = \_ -> pure (Right (Response "hi" [] (Usage 1 1)))
  , world  = \_ -> pure (Obs "")
  }

