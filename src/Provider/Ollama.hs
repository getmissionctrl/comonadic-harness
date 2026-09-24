-- | The real oracle: an Ollama-backed 'Provider' talking to a Qwen model on a
-- remote host.
--
-- __What.__ Supplies @complete@ (the model) for a live run. The companion
-- 'Provider.Tools.sandboxAct' supplies @act@ (the world); together they replace
-- the scripted stubs. @ollama-haskell 0.2.1.0@ is used purely as an HTTP
-- client — all tool\/affordance semantics live in the harness, never in this
-- library.
--
-- __Overflow inference (the one @[speculative]@ corner).__ Ollama 0.32.13
-- /silently truncates/ the prompt when it exceeds @num_ctx@ and continues
-- generating with @doneReason = \"stop\"@. There is no overflow error, flag, or
-- distinct done-reason to key on (@\"length\"@ fires only when @numPredict@ is
-- set, which we do not set). So the only signal we have is a /character-budget
-- heuristic/: compare @promptEvalCount@ (tokens actually evaluated) against a
-- rough character estimate of the prompt, and if the model evaluated far fewer
-- tokens than the prompt's length implies, infer that it was truncated and
-- report 'Harness.Alphabet.Overflow'. This is inference, not a reported fact —
-- @decodeResp@ documents the exact threshold and keeps the @[speculative]@ tag.
-- See @docs\/ollama-notes.md@ for the empirical basis (version numbers, observed
-- counts).
module Provider.Ollama
  ( OllamaCfg (..)
  , defaultOllamaCfg
  , ollamaOracle
  , ollamaProvider
  , streamingComplete
  , overflowByEstimate
  ) where

import Control.Concurrent (threadDelay)
import Control.Monad (when)
import Control.Monad.Except (MonadError, throwError)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson (decode, encode)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.ByteString.Lazy.Char8 qualified as BSLC
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map qualified as Map
import Data.Maybe (fromMaybe)
import Data.Ollama.Chat
  ( ChatOps (..)
  , InputTool (..)
  , assistantMessage
  , chat
  , defaultChatOps
  , toolMessage
  , userMessage
  )
import Data.Ollama.Common.Config (OllamaConfig (..), defaultOllamaConfig)
import Data.Ollama.Common.Error (OllamaError (..))
import Data.Ollama.Common.Types
  ( ChatResponse (..)
  , FunctionDef (..)
  , FunctionParameters (..)
  , Message (content, thinking, tool_calls)
  , ModelOptions (..)
  , OutputFunction (..)
  , ToolCall (..)
  )
import Data.Ollama.Common.Utils (defaultModelOptions)
import Data.Text qualified as T
import Harness.Alphabet
import Harness.Fault (ProviderError (..))
import Provider.Class (Provider (..))

-- | Everything the provider needs to reach a specific model on a specific
-- server. A plain record so a test can vary one field (typically 'ocNumCtx') and
-- leave the rest at 'defaultOllamaCfg'.
data OllamaCfg = OllamaCfg
  { ocBaseUrl :: String
  -- ^ Base URL of the Ollama server, e.g. @\"http:\/\/localhost:11434\"@. Passed
  -- through to the client as its @hostUrl@; no trailing path is appended here.
  , ocModel   :: String
  -- ^ The model tag, e.g. @\"qwen3:8b\"@. Sent as the request's @modelName@.
  -- Keep it here rather than as a literal in code so @docs\/ollama-notes.md@ has
  -- a single referent.
  , ocNumCtx  :: Int
  -- ^ The context window in /tokens/, sent as the @num_ctx@ model option.
  -- Deliberately exposed because it is the experimental knob: setting it low
  -- (e.g. 64 or 256) forces the prompt to overflow, which is how we provoke and
  -- study the silent-truncation behaviour that @decodeResp@ turns into
  -- 'Harness.Alphabet.Overflow'.
  , ocThink   :: Maybe Bool
  -- ^ Whether the model should \"think\" (reasoning tokens), sent as the chat
  -- request's @think@ flag. 'Nothing' leaves the model default. Set 'Just' 'False'
  -- for multi-turn agentic loops where a thinking model's per-turn reasoning is
  -- the dominant latency and adds little to tool selection.
  }

-- | The house configuration: a local Ollama server, the @qwen3:8b@ model, and
-- Ollama's own default 2048-token context.
--
-- __Why these values.__ They are the ones recorded as tested in
-- @docs\/ollama-notes.md@, so a run left at the default reproduces the documented
-- behaviour. Override 'ocNumCtx' (via record update) for overflow experiments
-- rather than editing this value. [established]
defaultOllamaCfg :: OllamaCfg
defaultOllamaCfg =
  OllamaCfg
    { ocBaseUrl = "http://localhost:11434"
    , ocModel   = "qwen3:8b"
    , ocNumCtx  = 2048
    , ocThink   = Nothing
    }

-- | The oracle half only — the model, with no world. Pair with an explicit
-- world (e.g. 'Provider.Tools.sandboxAct') to build a 'Provider', or use it
-- directly as an 'Harness.Run.Env' oracle. There is deliberately no bundled
-- world: a live oracle with silent no-op tools is a footgun (F6).
--
-- __Monad.__ Polymorphic in @m@ (not specialised to @IO@) so the live oracle
-- can ride the interpreter's error channel: a transport fault is raised as a
-- @'ProviderError'@ rather than a 'Refusal' (invariant 5), which needs a
-- @'MonadError' 'ProviderError'@ context — in practice @Harness.Run.Live@.
ollamaOracle
  :: (MonadIO m, MonadError ProviderError m)
  => OllamaCfg -> Request -> m (Either Refusal Response)
ollamaOracle = completeWith

-- | Build a live 'Provider' from a config and an EXPLICIT world. There is no
-- default no-op world (F6): the caller must choose what @act@ does, so a live
-- run cannot silently acknowledge tool calls without performing them.
--
-- __Monad.__ Polymorphic in @m@ for the same reason as 'ollamaOracle': the
-- oracle half needs @'MonadError' 'ProviderError'@; the world @w@ supplied by
-- the caller must be lawful in the same monad.
ollamaProvider
  :: (MonadIO m, MonadError ProviderError m)
  => OllamaCfg -> (Call -> m Obs) -> Provider m
ollamaProvider cfg w = Provider { complete = completeWith cfg, act = w }

-- ---------------------------------------------------------------------------
-- Internal: oracle
-- ---------------------------------------------------------------------------

-- | The live oracle: build the chat request, send it (with transient-error
-- retry), and decode the reply into our alphabet.
--
-- __How.__ @buildChatOps@ projects our 'Request' onto the client's @ChatOps@;
-- @withLocalRetry@ shields the call so a timeout or 5xx is retried rather than
-- escaping; then the result is folded. A /transient/ fault that survives retry
-- ('HttpError'\/'TimeoutError') is raised on the error channel as a
-- @'ProviderError'@ — it is transport failure, not a verdict, so it must not
-- reach the coalgebra as a 'Refusal' (invariant 5); @Harness.Run.run@ surfaces
-- it to the caller and the state stays resumable. Every /other/ hard client
-- error is a genuine, terminal model\/decode failure and becomes
-- 'Harness.Alphabet.Malformed'. A successful reply is handed to @decodeResp@,
-- which may still infer 'Harness.Alphabet.Overflow'. [established]
completeWith
  :: (MonadIO m, MonadError ProviderError m)
  => OllamaCfg -> Request -> m (Either Refusal Response)
completeWith cfg req = do
  let ops      = buildChatOps cfg req
      ollamaCfg = defaultOllamaConfig { hostUrl = T.pack (ocBaseUrl cfg) }
  result <- liftIO (withLocalRetry 3 (chat ops (Just ollamaCfg)))
  case result of
    Left err
      | isTransient err -> throwError (ProviderUnavailable (show err))
      | otherwise       -> pure (Left (Malformed (show err)))
    Right resp          -> pure (decodeResp cfg req resp)

-- | A __streaming__ oracle: identical to 'completeWith' in what it returns, but
-- it calls @onDelta@ with each text fragment as the model emits it, so a caller
-- (the AG-UI server) can forward tokens to the client live instead of waiting
-- for the whole turn. The full 'Response' (accumulated text, tool calls, usage)
-- is still returned for the coalgebra.
--
-- __How.__ Sets @ChatOps.stream@; the per-chunk callback accumulates @content@
-- (streaming each delta out via @onDelta@), forwards any @thinking@ delta via
-- @onThink@ (a thinking model emits reasoning in a /separate/ field, not in
-- @content@ — without this the reasoning is silently dropped), captures any
-- @tool_calls@, and reads usage from the terminal @done@ chunk. We accumulate
-- ourselves rather than trusting the library's returned aggregate, and skip
-- 'withLocalRetry' — a retry would re-emit already-streamed deltas — so a
-- transient fault surfaces as 'Malformed' and ends the run (a fair trade for
-- clean streaming). Reasoning is /not/ accumulated into the 'Response': it is
-- presentation only and never part of the answer the coalgebra consumes. [design]
streamingComplete
  :: OllamaCfg
  -> (T.Text -> IO ())  -- ^ @onDelta@: a fragment of the answer text
  -> (T.Text -> IO ())  -- ^ @onThink@: a fragment of the reasoning (\"thinking\") text
  -> Request
  -> IO (Either Refusal Response)
streamingComplete cfg onDelta onThink req = do
  accRef   <- newIORef []            -- content fragments, reversed
  callsRef <- newIORef Nothing       -- last seen tool_calls
  usageRef <- newIORef (0, 0)        -- (promptEvalCount, evalCount) from the done chunk
  let ollamaCfg = defaultOllamaConfig { hostUrl = T.pack (ocBaseUrl cfg) }
      onChunk cr = do
        case message cr of
          Just m -> do
            mapM_ (\t -> when (not (T.null t)) (onThink t)) (thinking m)
            let d = content m
            when (not (T.null d)) $ do
              modifyIORef' accRef (d :)
              onDelta d
            case tool_calls m of
              Just tcs -> writeIORef callsRef (Just tcs)
              Nothing  -> pure ()
          Nothing -> pure ()
        when (done cr) $
          writeIORef usageRef
            ( maybe 0 fromIntegral (promptEvalCount cr)
            , maybe 0 fromIntegral (evalCount cr) )
      ops = (buildChatOps cfg req) { stream = Just (onChunk, pure ()) }
  result <- chat ops (Just ollamaCfg)
  case result of
    Left err -> pure (Left (Malformed (show err)))
    Right _  -> do
      said       <- (T.concat . reverse) <$> readIORef accRef
      mcalls     <- readIORef callsRef
      (pin, out) <- readIORef usageRef
      pure $
        if overflowByEstimate cfg (sentText req)
          then Left Overflow
          else Right Response
            { say   = T.unpack said
            , calls = maybe [] (map toCall) mcalls
            , usage = Usage { inTok = pin, outTok = out }
            }

-- | Translate our 'Request' plus an 'OllamaCfg' into the client's @ChatOps@.
--
-- __How.__ The projected prompt becomes a single user message; the afforded
-- 'Harness.Alphabet.ToolSpec's become @tools@ via @toInputTool@; and 'ocNumCtx'
-- rides in as the @num_ctx@ model option. We send exactly one user message
-- rather than replaying the whole transcript, because the harness has /already/
-- folded the history into the projected prompt — the model's own multi-message
-- memory would double-count it. [design]
buildChatOps :: OllamaCfg -> Request -> ChatOps
buildChatOps cfg req =
  let Prompt promptText = reqPrompt req
      -- Native structured transport (Working mode): map the harness's structured
      -- turns to system / assistant(tool_calls) / tool messages. Falls back to
      -- the single flattened user message when 'reqMessages' is empty (the
      -- Summarising/compaction path, and any provider that only sets reqPrompt).
      native = concatMap toOllamaMsgs (reqMessages req)
      msgs   = case native of
                 (m : ms) -> m :| ms
                 []       -> userMessage (T.pack promptText) :| []
  in  defaultChatOps
        { modelName = T.pack (ocModel cfg)
        , messages  = msgs
        , tools     = Just (map toInputTool (reqTools req))
        , options   = Just defaultModelOptions { numCtx = Just (ocNumCtx cfg) }
        , think     = ocThink cfg
        }

-- | Map one harness 'ChatMsg' to native Ollama 'Message's: a summary/system as a
-- system message, an assistant turn as an assistant message carrying its
-- @tool_calls@, and a tool result as a @tool@-role message.
toOllamaMsgs :: ChatMsg -> [Message]
toOllamaMsgs (MsgUser t)              = [userMessage (T.pack t)]
toOllamaMsgs (MsgAssistant sy cs)     =
  -- An assistant turn that only calls tools has no text, but ollama-haskell
  -- always serialises 'content' and this model rejects an empty-content message
  -- (the native protocol's @content: null@ is not expressible here), so use a
  -- minimal non-empty placeholder when there is no commentary.
  let txt  = if null sy then "." else T.pack sy
      base = assistantMessage txt
  in  [ if null cs then base else base { tool_calls = Just (map toOllamaToolCall cs) } ]
toOllamaMsgs (MsgToolResult _ (Obs o)) = [toolMessage (T.pack o)]

-- | Rebuild a native 'ToolCall' from a harness 'Call' so a replayed assistant
-- turn carries the calls it made (the @tool@ results that follow are matched to
-- them). Arguments are the model's raw JSON re-parsed to the key/value map the
-- client expects; an unparseable blob degrades to no arguments.
toOllamaToolCall :: Call -> ToolCall
toOllamaToolCall c = ToolCall
  { outputFunction = OutputFunction
      { outputFunctionName = T.pack (tool c)
      , arguments          = fromMaybe Map.empty (decode (BSLC.pack (args c)))
      }
  }

-- | Convert a harness 'Harness.Alphabet.ToolSpec' into the client's @InputTool@.
--
-- __Gotcha, deliberately accepted.__ We advertise a permissive empty-parameter
-- object schema and do /not/ translate 'Harness.Alphabet.specSchema' into a
-- typed parameter tree. qwen3:8b tolerates loose tool definitions and infers
-- sensible argument keys from the prompt anyway (observed: it emits
-- @{\"location\":…}@ for a weather tool with no declared parameters). The cost is
-- that 'Provider.Tools.sandboxAct' must then look arguments up under several
-- plausible keys — a trade recorded in @docs\/ollama-notes.md@. [design]
toInputTool :: ToolSpec -> InputTool
toInputTool t =
  InputTool
    { toolType = "function"
    , function = FunctionDef
        { functionName        = T.pack (specName t)
        , functionDescription = Nothing
        , functionParameters  = Just (schemaOf (specSchema t))
        , functionStrict      = Nothing
        }
    }

-- | Translate a 'ToolSpec' mini-schema (@"{url:string}"@,
-- @"{path:string,body:string}"@) into a typed 'FunctionParameters' object, so a
-- strict tool-calling model emits correctly-named arguments instead of guessing.
-- The old empty-schema advertisement is why a stricter model emitted @{}@.
schemaOf :: String -> FunctionParameters
schemaOf spec = FunctionParameters
  { parameterType        = "object"
  , parameterProperties  = Just (Map.fromList [ (n, leaf ty) | (n, ty) <- props ])
  , requiredParams       = Just (map fst props)
  , additionalProperties = Just False
  }
  where
    props = parseSpec spec
    leaf ty = FunctionParameters
      { parameterType        = ty
      , parameterProperties  = Nothing
      , requiredParams       = Nothing
      , additionalProperties = Nothing
      }

-- | Parse the terse @{k:type,...}@ tool-schema DSL into @[(name, jsonType)]@.
parseSpec :: String -> [(T.Text, T.Text)]
parseSpec raw =
  [ (T.pack (trim k), jsonType (trim (drop 1 v)))
  | field <- splitComma inner
  , let (k, v) = break (== ':') field
  , not (null (trim k))
  ]
  where
    inner = takeWhile (/= '}') (drop 1 (dropWhile (/= '{') raw))
    trim  = f . f where f = reverse . dropWhile (== ' ')
    jsonType :: String -> T.Text
    jsonType ty
      | ty `elem` ["int", "integer", "number"] = "number"
      | ty `elem` ["bool", "boolean"]          = "boolean"
      | otherwise                               = "string"
    splitComma [] = []
    splitComma s  = let (a, b) = break (== ',') s
                    in a : case b of [] -> []; (_ : rest) -> splitComma rest

-- | The text actually sent to the model for a request: the concatenation of the
-- native 'reqMessages' when present (that is what goes on the wire), falling
-- back to the flattened 'reqPrompt' (the compaction\/summarising path sends a
-- single flattened message). Used only for the overflow token estimate, and
-- kept as ONE definition so the two decode paths ('decodeResp' and
-- 'streamingComplete') cannot drift. [design]
sentText :: Request -> String
sentText req = case reqMessages req of
  [] -> let Prompt p = reqPrompt req in p
  ms -> concatMap renderMsg ms
  where
    renderMsg (MsgUser t)               = t
    renderMsg (MsgAssistant t cs)       = t ++ concatMap (\c -> " " ++ tool c ++ " " ++ args c) cs
    renderMsg (MsgToolResult _ (Obs o)) = o

-- | Infer prompt overflow from the CONFIGURED window, not from
-- @promptEvalCount@. Estimate prompt tokens at ~4 chars/token and compare to
-- @ocNumCtx@ with a margin for chat-template / tool-schema overhead. This
-- deliberately does NOT read the evaluated-token count: under prefix/KV caching
-- a long cached prompt evaluates few new tokens, which the old heuristic
-- mistook for truncation (F3). Still [speculative] — it is an estimate; a native
-- overflow signal or an exact tokeniser would supersede it. See
-- @docs\/ollama-notes.md@.
overflowByEstimate :: OllamaCfg -> String -> Bool
overflowByEstimate cfg promptText =
  let estTokens    = length promptText `div` 4
      budgetTokens = (ocNumCtx cfg * 85) `div` 100  -- ~15% headroom for template/tool overhead
  in  estTokens > budgetTokens

-- | Decode a successful @ChatResponse@ into our 'Response', or infer
-- 'Harness.Alphabet.Overflow'.
--
-- __What.__ On the happy path, lifts @say@\/@calls@\/@usage@ out of the reply.
-- Overflow is inferred by 'overflowByEstimate': compare the estimated token
-- count of the /actually-sent/ content against 'ocNumCtx'. When 'reqMessages'
-- is non-empty that content is on the wire; 'reqPrompt' is the fallback for the
-- compaction\/summarising path that sends a single flattened message. This also
-- fixes the drift between @reqPrompt@ and @reqMessages@ noted in review1 #9.
decodeResp :: OllamaCfg -> Request -> ChatResponse -> Either Refusal Response
decodeResp cfg req resp
  | overflowByEstimate cfg (sentText req) = Left Overflow
  | otherwise  = Right Response
      { say   = maybe "" (T.unpack . content) (message resp)
      , calls = maybe [] (map toCall) (message resp >>= tool_calls)
      , usage = Usage
          { inTok  = maybe 0 fromIntegral (promptEvalCount resp)
          , outTok = maybe 0 fromIntegral (evalCount resp)
          }
      }

-- | Convert one library @ToolCall@ into our 'Harness.Alphabet.Call'.
--
-- __How.__ Takes the function name verbatim and re-encodes its @arguments@ back
-- to a compact JSON string, because the harness carries tool arguments as raw
-- text (the sandbox executor re-parses them). [design]
toCall :: ToolCall -> Call
toCall tc =
  let fn   = outputFunction tc
      name = T.unpack (outputFunctionName fn)
      args = BSLC.unpack (encode (arguments fn))
  in  Call { tool = name, args = args }

-- ---------------------------------------------------------------------------
-- Internal: local retry for transient errors
-- ---------------------------------------------------------------------------

-- | Retry an action up to @n@ times (1 s between attempts) on /transient/
-- errors, returning the first non-transient result.
--
-- __Why here and not in the coalgebra.__ This is invariant 5 made concrete:
-- retries, backoff and connection errors are the provider's business and must
-- never reach the coalgebra as a 'Harness.Alphabet.Refusal'. @HttpError@ and
-- @TimeoutError@ are treated as transient (see @isTransient@) and retried; every
-- other 'Data.Ollama.Common.Error.OllamaError' surfaces immediately, to be
-- mapped to 'Harness.Alphabet.Malformed' upstream. A terminal decode failure is
-- thus distinguishable from a flaky network. [established]
withLocalRetry :: Int -> IO (Either OllamaError a) -> IO (Either OllamaError a)
withLocalRetry 0 action = action
withLocalRetry n action = do
  result <- action
  case result of
    Left err | isTransient err -> do
        threadDelay 1_000_000
        withLocalRetry (n - 1) action
    _ -> pure result

-- | Which errors @withLocalRetry@ should retry: network-level faults only. A
-- decode or model error is /not/ transient — retrying it just wastes a second.
isTransient :: OllamaError -> Bool
isTransient (HttpError _)    = True
isTransient (TimeoutError _) = True
isTransient _                = False
