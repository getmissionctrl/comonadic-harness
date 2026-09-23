{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | A web-scraping world tool: @scrape_url@, backed by the Firecrawl API. This
-- is a second real world seam alongside 'Provider.Tools.sandboxAct' — it lets a
-- live agent /read the web/ (fetch a URL to clean markdown) in addition to the
-- sandboxed filesystem tools.
--
-- Copied and adapted from the @vf-haskell@ research harness so the two projects
-- share the same tool contract. The Firecrawl API key is supplied by the caller
-- (read from the environment in @app-serve/Serve.hs@), never hardcoded here.
-- Like every world seam it is total: any failure comes back as an error 'Obs'
-- the model can read, never an exception that escapes the run (crash-freedom, E4).
module Provider.Research
  ( scrapeUrlSpec
  , scrapeUrl
  , urlArg
  ) where

import Control.Exception (SomeException, try)
import Data.Aeson (Value (..), decode, encode, object, (.=))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Network.HTTP.Client
  ( Manager, RequestBody (RequestBodyLBS), httpLbs, parseRequest, requestBody
  , requestHeaders, responseBody, responseStatus, responseTimeout
  , responseTimeoutMicro )
import Network.HTTP.Types.Status (statusCode)

import Harness.Alphabet (ToolSpec (..))

-- | The tool spec advertised to the model. The @{url:string}@ mini-schema is
-- translated to a typed parameter object by 'Provider.Ollama.schemaOf', so a
-- tool-calling model emits @{"url":"…"}@.
scrapeUrlSpec :: ToolSpec
scrapeUrlSpec = ToolSpec "scrape_url" "{url:string}"

-- | Scrape one URL to clean markdown via Firecrawl v2 (@onlyMainContent@ drops
-- nav/boilerplate; @maxAge@ serves a cached scrape when fresh). 30s timeout,
-- result truncated to 8000 chars. Never throws — a failure comes back as an
-- error string the agent can read.
scrapeUrl :: Manager -> Text -> Text -> IO Text
scrapeUrl mgr apiKey url0 = do
  -- Normalise a bare host ("anthropic.com/news") to an absolute URL; models
  -- routinely drop the scheme.
  let url  = if "://" `T.isInfixOf` url0 then url0 else "https://" <> url0
      body = encode (object
        [ "url"             .= url
        , "onlyMainContent" .= True
        , "maxAge"          .= (172800000 :: Int)
        , "formats"         .= (["markdown"] :: [Text]) ])
  r <- try $ do
    req0 <- parseRequest "POST https://api.firecrawl.dev/v2/scrape"
    let req = req0
          { requestHeaders =
              [ ("Authorization", "Bearer " <> encodeUtf8 apiKey)
              , ("Content-Type", "application/json") ]
          , requestBody     = RequestBodyLBS body
          , responseTimeout = responseTimeoutMicro (30 * 1000000) }
    httpLbs req mgr
  pure $ case r of
    Left (e :: SomeException) -> "scrape error: " <> T.pack (show e)
    Right resp
      | statusCode (responseStatus resp) == 200 ->
          maybe "scrape error: no markdown in response" (T.take 8000)
                (scrapeMarkdown (responseBody resp))
      | otherwise ->
          "scrape error: status " <> T.pack (show (statusCode (responseStatus resp)))

-- | Extract @data.markdown@ from a Firecrawl v2 @/scrape@ response body.
scrapeMarkdown :: BL.ByteString -> Maybe Text
scrapeMarkdown b = case decode b of
  Just (Object o) -> case KM.lookup (K.fromString "data") o of
    Just (Object d) -> case KM.lookup (K.fromString "markdown") d of
      Just (String md) -> Just md
      _                -> Nothing
    _ -> Nothing
  _ -> Nothing

-- | Pull the URL out of a tool-call args JSON blob (best-effort). Prefer the
-- @"url"@ key, but a model may emit the URL under an invented key, so fall back
-- to the first string value so the call still round-trips instead of silently
-- becoming an empty-URL error.
urlArg :: String -> Text
urlArg s = case decode (BLC.pack s) :: Maybe Value of
  Just (Object o) -> case KM.lookup (K.fromString "url") o of
    Just (String t) -> t
    _               -> case [ t | String t <- KM.elems o ] of
                         (t : _) -> t
                         []      -> ""
  _ -> ""
