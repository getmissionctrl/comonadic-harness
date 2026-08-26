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
  , ollamaProvider
  ) where

import Control.Concurrent (threadDelay)
import Data.Aeson (encode)
import Data.ByteString.Lazy.Char8 qualified as BSLC
import Data.List.NonEmpty (NonEmpty (..))
import Data.Ollama.Chat
  ( ChatOps (..)
  , InputTool (..)
  , chat
  , defaultChatOps
  , userMessage
  )
import Data.Ollama.Common.Config (OllamaConfig (..), defaultOllamaConfig)
import Data.Ollama.Common.Error (OllamaError (..))
import Data.Ollama.Common.Types
  ( ChatResponse (..)
  , FunctionDef (..)
  , FunctionParameters (..)
  , Message (content, tool_calls)
  , ModelOptions (..)
  , OutputFunction (..)
  , ToolCall (..)
  )
import Data.Ollama.Common.Utils (defaultModelOptions)
import Data.Text qualified as T
import Harness.Alphabet
import Provider.Class (Provider (..))

-- | Everything the provider needs to reach a specific model on a specific
-- server. A plain record so a test can vary one field (typically 'ocNumCtx') and
-- leave the rest at 'defaultOllamaCfg'.
data OllamaCfg = OllamaCfg
  { ocBaseUrl :: String
  -- ^ Base URL of the Ollama server, e.g. @\"http:\/\/hq:11434\"@. Passed
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
  }

-- | The house configuration: the @hq@ host, the @qwen3:8b@ model, and Ollama's
-- own default 2048-token context.
--
-- __Why these values.__ They are the ones recorded as tested in
-- @docs\/ollama-notes.md@, so a run left at the default reproduces the documented
-- behaviour. Override 'ocNumCtx' (via record update) for overflow experiments
-- rather than editing this value. [established]
defaultOllamaCfg :: OllamaCfg
defaultOllamaCfg =
  OllamaCfg
    { ocBaseUrl = "http://hq:11434"
    , ocModel   = "qwen3:8b"
    , ocNumCtx  = 2048
    }

-- | Assemble a 'Provider' from a config: a real oracle, and — for now — a stub
-- world.
--
-- __What.__ @complete@ is wired to @completeWith@, the live HTTP oracle. @act@
-- is a placeholder that echoes @\"\<tool\>:ok\"@ without doing anything: this
-- module owns the /oracle/ half of the seam only. A live run that wants real
-- tool effects pairs this provider's @complete@ with
-- 'Provider.Tools.sandboxAct' as its world (see @Harness.Run.Env@), rather than
-- using this stub. [design]
ollamaProvider :: OllamaCfg -> Provider IO
ollamaProvider cfg =
  Provider
    { complete = completeWith cfg
    , act      = \c -> pure (Obs (tool c ++ ":ok"))  -- stub; the live world is Provider.Tools.sandboxAct
    }

-- ---------------------------------------------------------------------------
-- Internal: oracle
-- ---------------------------------------------------------------------------

-- | The live oracle: build the chat request, send it (with transient-error
-- retry), and decode the reply into our alphabet.
--
-- __How.__ @buildChatOps@ projects our 'Request' onto the client's @ChatOps@;
-- @withLocalRetry@ shields the call so a timeout or 5xx is retried rather than
-- escaping; then the result is folded to @Either Refusal Response@. A hard
-- client error that survives retry becomes 'Harness.Alphabet.Malformed' (a
-- terminal refusal), and a successful reply is handed to @decodeResp@, which may
-- still infer 'Harness.Alphabet.Overflow'. Nothing transient reaches the caller
-- — invariant 5. [established]
completeWith :: OllamaCfg -> Request -> IO (Either Refusal Response)
completeWith cfg req = do
  let ops      = buildChatOps cfg req
      ollamaCfg = defaultOllamaConfig { hostUrl = T.pack (ocBaseUrl cfg) }
  result <- withLocalRetry 3 (chat ops (Just ollamaCfg))
  pure $ case result of
    Left err   -> Left (Malformed (show err))
    Right resp -> decodeResp req resp

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
  in  defaultChatOps
        { modelName = T.pack (ocModel cfg)
        , messages  = userMessage (T.pack promptText) :| []
        , tools     = Just (map toInputTool (reqTools req))
        , options   = Just defaultModelOptions { numCtx = Just (ocNumCtx cfg) }
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
        , functionParameters  = Just emptyParams
        , functionStrict      = Nothing
        }
    }
  where
    emptyParams = FunctionParameters
      { parameterType        = "object"
      , parameterProperties  = Nothing
      , requiredParams       = Nothing
      , additionalProperties = Nothing
      }

-- | Decode a successful @ChatResponse@ into our 'Response', or infer
-- 'Harness.Alphabet.Overflow'.
--
-- __What.__ On the happy path, lifts @say@\/@calls@\/@usage@ out of the reply.
-- The interesting work is deciding whether the reply is /trustworthy/ or the
-- product of a silently truncated prompt.
--
-- __The overflow heuristic. [speculative]__ Ollama 0.32.13 + qwen3:8b truncates
-- the prompt silently when it overflows @num_ctx@; @doneReason@ stays
-- @\"stop\"@ in /all/ cases (it becomes @\"length\"@ only when @numPredict@ is
-- set explicitly, which we do not do). So there is no reported signal, and we
-- /infer/ truncation from a character-budget comparison:
--
--   if  @promptEvalCount * charsPerTok < 0.6 × length(promptText)@
--   and the prompt is non-trivially large (> 80 chars ≈ 20 tokens),
--   the prompt was truncated.
--
-- __Why these constants.__ @charsPerTok = 4@ is the standard rough English
-- average; the @0.6@ factor makes the test /conservative/ — it fires only when
-- the tokens actually evaluated fall well below what the prompt length implies,
-- so it errs toward FEWER false positives (a genuinely dense or Unicode-heavy
-- prompt will not be mistaken for a truncated one). The @> 80@ guard stops a
-- short prompt, whose count is dominated by fixed chat-template overhead, from
-- tripping the test. This is the one part of the module that is an educated
-- guess rather than a reported fact, which is why it keeps the @[speculative]@
-- tag; its empirical grounding (observed counts at @numCtx@ 64 and 256) is in
-- @docs\/ollama-notes.md@.
decodeResp :: Request -> ChatResponse -> Either Refusal Response
decodeResp req resp
  | isOverflow = Left Overflow
  | otherwise  = Right Response
      { say   = maybe "" (T.unpack . content) (message resp)
      , calls = maybe [] (map toCall) (message resp >>= tool_calls)
      , usage = Usage
          { inTok  = maybe 0 fromIntegral (promptEvalCount resp)
          , outTok = maybe 0 fromIntegral (evalCount resp)
          }
      }
  where
    Prompt promptText = reqPrompt req
    promptChars       = length promptText
    -- rough token estimate: 1 token ≈ 4 chars for English
    charsPerTok :: Double
    charsPerTok = 4.0
    estimatedTok :: Double
    estimatedTok = fromIntegral promptChars / charsPerTok
    isOverflow = case promptEvalCount resp of
      Nothing  -> False
      Just pec ->
        -- only flag overflow for non-trivial prompts
        promptChars > 80
        && fromIntegral pec < 0.6 * estimatedTok

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
