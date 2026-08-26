{-# LANGUAGE OverloadedStrings #-}

-- | A real world seam: an executor that actually runs the harness's tool calls,
-- confined to a sandbox directory. This is the counterpart to 'Provider.Ollama'
-- (which supplies the oracle) — here we supply the /world/, so a live run can do
-- genuine work instead of the @":ok"@ stub.
--
-- Everything is rooted at a sandbox directory and cannot escape it:
--
--   * @read@\/@write@ resolve their path inside the sandbox; a @..@ escape is
--     refused rather than followed.
--   * @bash@ runs with the sandbox as its working directory and a wall-clock
--     timeout, so a hung or runaway command cannot block the run forever.
--   * @commit@ is a @git commit@ in the sandbox's /own/ repository, seeded by
--     'prepareSandbox' — the surrounding project repo is never touched.
--
-- The model does not reliably use the schema's argument names (qwen3 emits
-- @{"filename":...}@ or @{"file":...}@ where the schema said @path@), so
-- 'sandboxAct' looks a call's value up under several plausible keys. [design]
module Provider.Tools
  ( prepareSandbox
  , sandboxAct
  ) where

import Control.Exception (SomeException, try)
import Data.Aeson (Value (..), decode, encode)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy.Char8 as BSLC
import Data.List (isPrefixOf)
import Data.Maybe (listToMaybe, mapMaybe)
import qualified Data.Text as T
import System.Directory
  ( canonicalizePath
  , copyFile
  , createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  )
import System.Exit (ExitCode (..))
import System.FilePath (normalise, takeDirectory, (</>))
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode, shell)
import System.Timeout (timeout)

import Harness.Alphabet (Call (..), Obs (..))

-- | Create the sandbox if absent, make it a git repository (so @commit@ works),
-- and seed it with a copy of @readmeSrc@ as @README.md@ so a @read@ of the
-- README returns real content. Idempotent: safe to call before every run.
prepareSandbox :: FilePath -> FilePath -> IO ()
prepareSandbox root readmeSrc = do
  createDirectoryIfMissing True root
  isRepo <- doesDirectoryExist (root </> ".git")
  if isRepo
    then pure ()
    else do
      _ <- runGit root ["init", "-q"]
      _ <- runGit root ["config", "user.email", "agent@harness.local"]
      _ <- runGit root ["config", "user.name", "harness-agent"]
      pure ()
  haveReadme <- doesFileExist readmeSrc
  if haveReadme then copyFile readmeSrc (root </> "README.md") else pure ()

-- | Execute one tool 'Call' inside the sandbox, returning the observation the
-- model sees next turn. Any 'IO' exception is caught and returned as an error
-- 'Obs' rather than thrown, so the world seam preserves the harness's
-- crash-freedom property (E4).
sandboxAct :: FilePath -> Call -> IO Obs
sandboxAct root c = do
  result <- try (dispatch root (tool c) (parseArgs (args c)))
  pure $ Obs $ case result of
    Left (e :: SomeException) -> "error: " ++ show e
    Right out                 -> out

-- ---------------------------------------------------------------------------
-- Dispatch
-- ---------------------------------------------------------------------------

dispatch :: FilePath -> String -> Args -> IO String
dispatch root tl a = case tl of
  "read"   -> readTool root (arg ["path", "filename", "file", "filepath"] a)
  "write"  -> writeTool root (arg ["path", "filename", "file", "filepath"] a)
                             (arg ["body", "content", "text", "data"] a)
  "bash"   -> bashTool root (arg ["cmd", "command", "script"] a)
  "commit" -> commitTool root (arg ["msg", "message", "m"] a)
  other    -> pure ("error: unknown tool " ++ other)

readTool :: FilePath -> Maybe String -> IO String
readTool _ Nothing = pure "error: read: no path argument"
readTool root (Just rel) = withSafePath root rel $ \p -> do
  ok <- doesFileExist p
  if not ok
    then pure ("error: no such file: " ++ rel)
    else do
      body <- readFile p
      pure ("read " ++ rel ++ " (" ++ show (length body) ++ " bytes):\n" ++ clip 800 body)

writeTool :: FilePath -> Maybe String -> Maybe String -> IO String
writeTool _ Nothing _ = pure "error: write: no path argument"
writeTool root (Just rel) mbody = withSafePath root rel $ \p -> do
  let body = maybe "" id mbody
  createDirectoryIfMissing True (takeDirectory p)
  writeFile p body
  pure ("wrote " ++ show (length body) ++ " bytes to " ++ rel)

bashTool :: FilePath -> Maybe String -> IO String
bashTool _ Nothing = pure "error: bash: no command argument"
bashTool root (Just cmd)
  | null cmd  = pure "error: bash: empty command"
  | otherwise = do
      let cp = (shell cmd) { cwd = Just root }
      mres <- timeout (10 * 1000000) (readCreateProcessWithExitCode cp "")
      case mres of
        Nothing              -> pure "error: bash: timed out after 10s"
        Just (code, out, err) ->
          pure ("bash " ++ showExit code ++ "\n" ++ clip 800 (out ++ err))

commitTool :: FilePath -> Maybe String -> IO String
commitTool root mmsg = do
  _ <- runGit root ["add", "-A"]
  (code, out, err) <- runGit root ["commit", "-m", maybe "agent commit" nonEmpty mmsg]
  pure ("git commit " ++ showExit code ++ ": " ++ firstLine (out ++ err))
  where
    nonEmpty s = if null s then "agent commit" else s

-- ---------------------------------------------------------------------------
-- Path safety
-- ---------------------------------------------------------------------------

-- | Run the action with a path that is guaranteed to sit inside the sandbox.
-- The candidate's directory is canonicalised and compared against the
-- canonical sandbox root, so a @..@ traversal (or an absolute path) that would
-- leave the sandbox is refused. [established]
withSafePath :: FilePath -> String -> (FilePath -> IO String) -> IO String
withSafePath root rel k
  | null rel  = pure "error: empty path"
  | otherwise = do
      let candidate = normalise (root </> rel)
      croot <- canonicalizePath root
      cdir  <- canonicalizePath (takeDirectory candidate)
      if croot == cdir || (croot ++ "/") `isPrefixOf` (cdir ++ "/")
        then k candidate
        else pure ("error: path escapes sandbox: " ++ rel)

-- ---------------------------------------------------------------------------
-- Argument parsing
-- ---------------------------------------------------------------------------

-- | A tool call's arguments: either a decoded JSON object, or a raw fallback
-- string when the model did not send an object.
data Args = Obj (KM.KeyMap Value) | Raw String

parseArgs :: String -> Args
parseArgs s = case decode (BSLC.pack s) of
  Just (Object o) -> Obj o
  Just (String t) -> Raw (T.unpack t)
  _               -> Raw s

-- | Look a value up under the first matching key. For a 'Raw' argument (a bare
-- string) every key resolves to that string — enough for single-argument tools
-- like @read@\/@bash@\/@commit@.
arg :: [String] -> Args -> Maybe String
arg _    (Raw r) = Just r
arg keys (Obj o) = listToMaybe (mapMaybe fromKey keys)
  where
    fromKey k = valueString <$> KM.lookup (K.fromString k) o

-- | Render a JSON value as a plain string: a JSON string as its text, anything
-- else as its compact JSON encoding (so a numeric or nested arg still shows).
valueString :: Value -> String
valueString (String t) = T.unpack t
valueString v          = BSLC.unpack (encode v)

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

runGit :: FilePath -> [String] -> IO (ExitCode, String, String)
runGit root as = readCreateProcessWithExitCode (proc "git" (["-C", root] ++ as)) ""

showExit :: ExitCode -> String
showExit ExitSuccess     = "ok"
showExit (ExitFailure n) = "exit=" ++ show n

-- | Truncate long tool output so a single read/bash does not blow the budget.
clip :: Int -> String -> String
clip n s
  | length s <= n = s
  | otherwise     = take n s ++ "… [+" ++ show (length s - n) ++ " chars]"

firstLine :: String -> String
firstLine = clip 200 . takeWhile (/= '\n')
