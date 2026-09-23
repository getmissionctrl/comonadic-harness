-- | Production entry point for the AG-UI server. Wires a provider factory into
-- the registry server and listens on a port (argv[0] or 8080).
--
-- v1 ships with the deterministic fake factory so the server runs without a
-- model in the loop — enough to exercise the transport, SSE framing and replay
-- end to end. The live Ollama factory (mirroring @app/Main.hs@'s
-- @Env (complete (ollamaProvider cfg)) (sandboxAct sandboxDir)@) is a follow-up;
-- see the TODO below.
module Main (main) where

import System.Environment (getArgs)
import Harness.AgUi.Server (serve', fakeProviderFactory)

main :: IO ()
main = do
  args <- getArgs
  let port = case args of
        (p : _) -> read p
        _       -> 8080
  putStrLn ("AG-UI harness server on http://localhost:" <> show port)
  putStrLn "POST /runs {\"task\":\"...\"}  |  GET /runs/{id}/events  |  POST /runs/{id}/input {\"text\":\"...\"}"
  -- TODO(live): swap for an Ollama-backed factory mirroring app/Main.hs — build
  -- an `Env (complete (ollamaProvider cfg)) (sandboxAct sandboxDir)` per run id.
  serve' port fakeProviderFactory
