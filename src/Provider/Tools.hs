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
--     /Caveat:/ this is @cwd@-confinement, not a security boundary — the command
--     runs with the harness's own uid and can read outside the sandbox (e.g.
--     @cat \/etc\/passwd@). Only @read@\/@write@ are path-confined; @bash@ is
--     trusted-input territory. [design]
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
import System.FilePath (isAbsolute, pathSeparator, splitDirectories, takeDirectory, (</>))
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode, shell)
import System.Timeout (timeout)

import Harness.Alphabet (Call (..), Obs (..))

-- | Prepare the sandbox directory so a live run has somewhere real to work.
--
-- __What.__ Creates @root@ if absent, makes it a git repository (so the @commit@
-- tool has something to commit /into/), and seeds it with a copy of @readmeSrc@
-- as @README.md@ so that a @read@ of the README returns genuine content rather
-- than an empty file.
--
-- __Why a git init here.__ @commit@ is implemented as @git commit@ in this very
-- directory; without an initialised repo (and a configured user name\/email) the
-- first commit would fail. Seeding the identity here keeps @commitTool@ free of
-- setup logic.
--
-- __Gotcha.__ Idempotent by design — the repo is only initialised when
-- @.git@ is absent, so it is safe (and intended) to call before /every/ run. The
-- README copy, however, is unconditional: a fresh @readmeSrc@ overwrites the
-- sandbox copy each time. [established]
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

-- | The live world: execute one tool 'Call' inside the sandbox and return the
-- 'Obs' the model sees next turn.
--
-- __What.__ This is the @act@ half of the provider seam for a real run — the
-- counterpart to 'Provider.Ollama'\'s oracle. It dispatches on the tool name
-- (@read@\/@write@\/@bash@\/@commit@) and runs the real effect, confined to
-- @root@.
--
-- __Why catch everything.__ Any @IO@ exception (a permission error, a decode
-- fault, a git failure) is caught and returned /as/ an error 'Obs' — prefixed
-- @\"error: \"@ — rather than thrown. A tool failing is normal agent territory
-- and must not crash the run: preserving that is the harness's crash-freedom
-- property (E4). The model simply sees the error string and decides what to do
-- next. [established]
sandboxAct :: FilePath -> Call -> IO Obs
sandboxAct root c = do
  result <- try (dispatch root (tool c) (parseArgs (args c)))
  pure $ Obs $ case result of
    Left (e :: SomeException) -> "error: " ++ show e
    Right out                 -> out

-- ---------------------------------------------------------------------------
-- Dispatch
-- ---------------------------------------------------------------------------

-- | Route a call to the tool that runs it, pulling each tool's argument out of
-- the (loosely-keyed) 'Args' by trying every plausible key name the model might
-- have used. An unknown tool name is a recoverable error string, not a crash.
dispatch :: FilePath -> String -> Args -> IO String
dispatch root tl a = case tl of
  "read"   -> readTool root (arg ["path", "filename", "file", "filepath"] a)
  "write"  -> writeTool root (arg ["path", "filename", "file", "filepath"] a)
                             (arg ["body", "content", "text", "data"] a)
  "bash"   -> bashTool root (arg ["cmd", "command", "script"] a)
  "commit" -> commitTool root (arg ["msg", "message", "m"] a)
  other    -> pure ("error: unknown tool " ++ other)

-- | @read@: return a clipped view of a file's contents. Path-confined through
-- @withSafePath@; a missing path or missing file is a plain error string.
readTool :: FilePath -> Maybe String -> IO String
readTool _ Nothing = pure "error: read: no path argument"
readTool root (Just rel) = withSafePath root rel $ \p -> do
  ok <- doesFileExist p
  if not ok
    then pure ("error: no such file: " ++ rel)
    else do
      body <- readFile p
      pure ("read " ++ rel ++ " (" ++ show (length body) ++ " bytes):\n" ++ clip 800 body)

-- | @write@: create or overwrite a file, making any missing parent directories.
-- Path-confined through @withSafePath@; an absent body is treated as empty. This
-- is an /irreversible/ tool — the compaction law tracks its use (see
-- 'Harness.Compaction.bWrites').
writeTool :: FilePath -> Maybe String -> Maybe String -> IO String
writeTool _ Nothing _ = pure "error: write: no path argument"
writeTool root (Just rel) mbody = withSafePath root rel $ \p -> do
  let body = maybe "" id mbody
  createDirectoryIfMissing True (takeDirectory p)
  writeFile p body
  pure ("wrote " ++ show (length body) ++ " bytes to " ++ rel)

-- | @bash@: run a shell command with the sandbox as its working directory and a
-- 10-second wall-clock timeout, returning the exit status and clipped
-- stdout+stderr. A timeout is reported as an error string so a hung command
-- cannot block the run forever.
--
-- __Caveat, not hidden.__ This is @cwd@-confinement, /not/ a security boundary.
-- The command runs with the harness's own uid and can read outside the sandbox
-- (@cat \/etc\/passwd@ works). Only @read@\/@write@ are path-confined; @bash@ is
-- trusted-input territory. [design]
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

-- | @commit@: stage everything and @git commit@ in the sandbox's /own/
-- repository (seeded by 'prepareSandbox'). The surrounding project repo is never
-- touched. An empty or absent message defaults to @\"agent commit\"@. Like
-- @write@, this is an irreversible tool the compaction law watches. [established]
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

-- | Run the action with a path guaranteed to sit inside the sandbox.
--
-- Two layers, because canonicalising alone is not enough: 'canonicalizePath'
-- leaves @..@ segments /uncollapsed/ when an earlier component does not yet
-- exist (so @a\/..\/..\/etc@ would slip a naive prefix check while the OS still
-- resolves the @..@ at write time). So we first refuse, lexically, any absolute
-- path or any path containing a @..@ segment — that alone confines the path to
-- the sandbox. We then canonicalise the /full/ candidate and re-check
-- containment, which additionally defeats a symlink a prior @write@\/@bash@ may
-- have planted inside the sandbox pointing out. [established]
withSafePath :: FilePath -> String -> (FilePath -> IO String) -> IO String
withSafePath root rel k
  | null rel                         = pure "error: empty path"
  | isAbsolute rel                   = pure ("error: absolute path not allowed: " ++ rel)
  | ".." `elem` splitDirectories rel = pure ("error: '..' not allowed in path: " ++ rel)
  | otherwise = do
      croot <- canonicalizePath root
      canon <- canonicalizePath (root </> rel)
      if croot == canon || (croot ++ [pathSeparator]) `isPrefixOf` canon
        then k (root </> rel)
        else pure ("error: path escapes sandbox: " ++ rel)

-- ---------------------------------------------------------------------------
-- Argument parsing
-- ---------------------------------------------------------------------------

-- | A tool call's arguments, after best-effort parsing: either a decoded JSON
-- @Obj@ect (the normal case) or a @Raw@ fallback string for when the model sent
-- a bare string or something that did not decode. The @Raw@ case is what lets
-- single-argument tools work even when the model omits the JSON envelope.
data Args = Obj (KM.KeyMap Value) | Raw String

-- | Parse a raw argument string leniently. A JSON object becomes 'Obj'; a JSON
-- string becomes 'Raw' of its text; anything else (including malformed JSON)
-- falls back to 'Raw' of the original string, so a mis-encoded argument still
-- reaches the tool rather than being dropped.
parseArgs :: String -> Args
parseArgs s = case decode (BSLC.pack s) of
  Just (Object o) -> Obj o
  Just (String t) -> Raw (T.unpack t)
  _               -> Raw s

-- | Look a value up under the first of several candidate keys that matches. The
-- candidate list exists because qwen3 does not reliably use the schema's
-- argument names — it emits @{\"filename\":…}@ or @{\"file\":…}@ where the
-- schema said @path@ — so each tool passes every plausible synonym. For a 'Raw'
-- argument (a bare string) any key resolves to that string, which is enough for
-- single-argument tools like @read@\/@bash@\/@commit@. [design]
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
