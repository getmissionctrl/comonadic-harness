-- | Real Ollama provider that talks to a Qwen model on a remote host.
--
-- ollama-haskell 0.2.1.0 is used purely as an HTTP client; tool\/affordance
-- semantics live in the harness, not in this library.
--
-- Overflow inference: Ollama 0.32.13 silently truncates the prompt when it
-- exceeds @num_ctx@ and continues generating with @doneReason = "stop"@.
-- There is no explicit overflow error or flag. We detect truncation by
-- comparing @promptEvalCount@ (actual tokens evaluated) against a rough
-- character-based estimate of the prompt length: if pec * 4 < len(prompt)
-- and the prompt is non-trivially long, the prompt was truncated.
-- See docs\/ollama-notes.md for the empirical basis.
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

-- | Configuration for the Ollama provider.
data OllamaCfg = OllamaCfg
  { ocBaseUrl :: String
  -- ^ Base URL for the Ollama server (e.g. @\"http:\/\/hq:11434\"@).
  , ocModel   :: String
  -- ^ Model tag to use (e.g. @\"qwen3:8b\"@).
  , ocNumCtx  :: Int
  -- ^ Context window size in tokens. Set low to provoke 'Overflow'.
  }

-- | Default configuration: hq host, qwen3:8b model, 2048-token context.
defaultOllamaCfg :: OllamaCfg
defaultOllamaCfg =
  OllamaCfg
    { ocBaseUrl = "http://hq:11434"
    , ocModel   = "qwen3:8b"
    , ocNumCtx  = 2048
    }

-- | Build a provider from an 'OllamaCfg'.
ollamaProvider :: OllamaCfg -> Provider IO
ollamaProvider cfg =
  Provider
    { complete = completeWith cfg
    , act      = \c -> pure (Obs (tool c ++ ":ok"))  -- stub; T6 wires real tools
    }

-- ---------------------------------------------------------------------------
-- Internal: oracle
-- ---------------------------------------------------------------------------

completeWith :: OllamaCfg -> Request -> IO (Either Refusal Response)
completeWith cfg req = do
  let ops      = buildChatOps cfg req
      ollamaCfg = defaultOllamaConfig { hostUrl = T.pack (ocBaseUrl cfg) }
  result <- withLocalRetry 3 (chat ops (Just ollamaCfg))
  pure $ case result of
    Left err   -> Left (Malformed (show err))
    Right resp -> decodeResp req resp

-- | Build a 'ChatOps' from our 'Request' and 'OllamaCfg'.
buildChatOps :: OllamaCfg -> Request -> ChatOps
buildChatOps cfg req =
  let Prompt promptText = reqPrompt req
  in  defaultChatOps
        { modelName = T.pack (ocModel cfg)
        , messages  = userMessage (T.pack promptText) :| []
        , tools     = Just (map toInputTool (reqTools req))
        , options   = Just defaultModelOptions { numCtx = Just (ocNumCtx cfg) }
        }

-- | Convert a harness 'ToolSpec' into a library 'InputTool'.
--
-- We use a permissive empty-parameter object schema: the local model
-- tolerates loose definitions, and we do NOT parse 'specSchema' into a typed
-- tree (out of scope for this task).
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

-- | Decode a successful 'ChatResponse' into our 'Response', or 'Overflow'.
--
-- Overflow inference: Ollama 0.32.13 + qwen3:8b truncates the prompt
-- silently when it overflows @num_ctx@; @doneReason@ stays @"stop"@ in ALL
-- cases (it only becomes @"length"@ when @numPredict@ is set explicitly,
-- which we do not do). The reliable signal is therefore a character-budget
-- comparison:
--
--   If  @promptEvalCount * charsPerTok < 0.6 × length(prompt_text)@
--   and the prompt is non-trivially large (> 80 chars ≈ 20 tokens),
--   the prompt was truncated.
--
-- @charsPerTok = 4@ is the standard English rough average and errs on the
-- side of FEWER false positives (we only fire if pec is well below the
-- estimated token count).
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

-- | Convert a library 'ToolCall' into our 'Call'.
toCall :: ToolCall -> Call
toCall tc =
  let fn   = outputFunction tc
      name = T.unpack (outputFunctionName fn)
      args = BSLC.unpack (encode (arguments fn))
  in  Call { tool = name, args = args }

-- ---------------------------------------------------------------------------
-- Internal: local retry for transient errors
-- ---------------------------------------------------------------------------

-- | Retry the action up to @n@ times (with a 1 s delay) on transient errors
-- ('HttpError', 'TimeoutError'). Terminal errors surface immediately without
-- retrying. This is invariant 5: transient failures never reach the coalgebra.
withLocalRetry :: Int -> IO (Either OllamaError a) -> IO (Either OllamaError a)
withLocalRetry 0 action = action
withLocalRetry n action = do
  result <- action
  case result of
    Left err | isTransient err -> do
        threadDelay 1_000_000
        withLocalRetry (n - 1) action
    _ -> pure result

isTransient :: OllamaError -> Bool
isTransient (HttpError _)    = True
isTransient (TimeoutError _) = True
isTransient _                = False
