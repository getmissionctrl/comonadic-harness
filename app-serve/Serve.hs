{-# LANGUAGE ScopedTypeVariables #-}

-- | Production entry point for the AG-UI server, wired to a __live__ Ollama
-- model against real tools.
--
-- The oracle is 'Provider.Ollama.ollamaProvider' (Qwen on the configured host);
-- the world routes @scrape_url@ to Firecrawl ('Provider.Research') and the
-- filesystem tools (@read@\/@write@\/@bash@\/@commit@) to the sandbox
-- ('Provider.Tools.sandboxAct'). So a browser driving @POST /agent@ gets a
-- genuine local-LLM agent that can read the web, edit files in a throwaway
-- sandbox, and commit.
--
-- Configuration comes from the environment (optionally seeded from a local,
-- git-ignored @.env@): @OLLAMA_BASE_URL@ (default @http:\/\/hq:11434@),
-- @OLLAMA_MODEL@ (default @qwen3:8b@), @OLLAMA_NUM_CTX@, @BUDGET@, and
-- @FIRECRAWL_API_KEY@ for the scrape tool. Secrets are never hardcoded here.
module Main (main) where

import Control.Exception (SomeException, try)
import Data.Char (isSpace)
import Data.List (isPrefixOf)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import System.IO (BufferMode (LineBuffering), hSetBuffering, stderr, stdout)
import Network.HTTP.Client (Manager)
import Network.HTTP.Client.TLS (newTlsManager)
import System.Environment (getArgs, lookupEnv, setEnv)
import Text.Read (readMaybe)

import Harness.Alphabet (Call (..), Obs (..))
import Harness.Run (Env (..))
import Harness.State (allTools)
import Provider.Class (Provider (..))
import Provider.Ollama (OllamaCfg (..), defaultOllamaCfg, ollamaProvider)
import Provider.Research (scrapeUrl, scrapeUrlSpec, urlArg)
import Provider.Tools (prepareSandbox, sandboxAct)
import Harness.AgUi.Server (ServeConfig (..), serveWith)

-- | The sandbox the live run's filesystem tools operate in — its own git repo,
-- seeded with a copy of the project README. The surrounding repo is untouched.
sandboxDir :: FilePath
sandboxDir = "runs/agent-sandbox"

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  loadDotEnv ".env"
  args <- getArgs
  let port = case args of
        (p : _) | Just n <- readMaybe p -> n
        _                               -> 8080

  baseUrl <- envOr "OLLAMA_BASE_URL" (ocBaseUrl defaultOllamaCfg)
  model   <- envOr "OLLAMA_MODEL" (ocModel defaultOllamaCfg)
  numCtx  <- envInt "OLLAMA_NUM_CTX" 8192
  budget  <- envInt "BUDGET" 40000
  apiKey  <- fromMaybe "" <$> lookupEnv "FIRECRAWL_API_KEY"

  mgr <- newTlsManager
  prepareSandbox sandboxDir "README.md"

  let cfg = defaultOllamaCfg
        { ocBaseUrl = baseUrl, ocModel = model, ocNumCtx = numCtx, ocThink = Just False }
      -- Live oracle (Ollama) + a world that adds web scraping to the sandbox tools.
      factory _rid = pure Env
        { oracle = complete (ollamaProvider cfg)
        , world  = liveWorld mgr (T.pack apiKey) sandboxDir
        }
      -- read/write/bash/commit + scrape_url, subject to the harness's affordance
      -- policy (no tools while summarising; commit withheld until a write).
      tools = allTools ++ [scrapeUrlSpec]
      serveCfg = ServeConfig { scfFactory = factory, scfTools = tools, scfBudget = budget }

  putStrLn ("AG-UI harness server (LIVE) on http://0.0.0.0:" <> show port)
  putStrLn ("  model      : " <> model <> " @ " <> baseUrl <> "  (num_ctx=" <> show numCtx <> ", budget=" <> show budget <> ")")
  putStrLn ("  tools      : read write bash commit scrape_url  (sandbox: " <> sandboxDir <> ")")
  putStrLn ("  firecrawl  : " <> if null apiKey then "NO KEY (scrape_url will error)" else "key loaded")
  putStrLn "  endpoints  : POST /agent (RunAgentInput)  |  POST /runs  |  GET /runs/{id}/events"
  serveWith port serveCfg

-- | The live world: @scrape_url@ hits Firecrawl; every other tool runs in the
-- sandbox. Total — a failure is an error 'Obs', never an exception.
liveWorld :: Manager -> T.Text -> FilePath -> Call -> IO Obs
liveWorld mgr apiKey root c
  | tool c == "scrape_url" = do
      md <- scrapeUrl mgr apiKey (urlArg (args c))
      pure (Obs (T.unpack md))
  | otherwise = sandboxAct root c

-- | Read an env var, or a default if unset.
envOr :: String -> String -> IO String
envOr k d = fromMaybe d <$> lookupEnv k

-- | Read an integer env var, falling back to a default if unset or unparseable.
envInt :: String -> Int -> IO Int
envInt k d = maybe d (fromMaybe d . readMaybe) <$> lookupEnv k

-- | Minimal @.env@ loader: for each @KEY=VALUE@ line, set the variable if it is
-- not already present in the real environment (so real env vars win). Missing
-- file is fine. No dependency on a dotenv library.
loadDotEnv :: FilePath -> IO ()
loadDotEnv fp = do
  r <- try (readFile fp) :: IO (Either SomeException String)
  case r of
    Left _  -> pure ()
    Right c -> mapM_ setLine (lines c)
  where
    setLine l0 =
      let l = dropWhile isSpace l0
      in if null l || "#" `isPrefixOf` l
           then pure ()
           else case break (== '=') l of
             (k, '=' : v) | not (null k) -> do
               existing <- lookupEnv k
               case existing of
                 Just _  -> pure ()
                 Nothing -> setEnv (trim k) (trim v)
             _ -> pure ()
    trim = f . f where f = reverse . dropWhile isSpace
