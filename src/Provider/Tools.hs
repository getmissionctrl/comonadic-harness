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
--   * @bash@ is __disabled by default__ in 'sandboxAct'. Use 'trustedShellWorld'
--     to opt in explicitly. Even then, this is @cwd@-confinement only — not a
--     security boundary. The command runs with the harness's own uid and can read
--     outside the sandbox (@cat \/etc\/passwd@ works). [design]
--   * @commit@ is a @git commit@ in the sandbox's /own/ repository, seeded by
--     'prepareSandbox' — the surrounding project repo is never touched.
--   * 'refWorld' additionally handles @jsonpath@\/@deref@ as selector calls
--     resolved from the reference store; these never reach 'dispatch'. [design]
--
-- The model does not reliably use the schema's argument names (qwen3 emits
-- @{"filename":...}@ or @{"file":...}@ where the schema said @path@), so
-- 'sandboxAct' looks a call's value up under several plausible keys. [design]
module Provider.Tools
  ( prepareSandbox
  , sandboxAct
  , trustedShellWorld
  , refWorld
  , onceReadWorld
  , parseArgs
  , arg
  ) where

import Control.Exception (SomeException, try)
import Data.Aeson (Value (..), decode, encode)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy.Char8 as BSLC
import Data.IORef (IORef, atomicModifyIORef', readIORef)
import Data.List (isPrefixOf)
import qualified Data.Map.Strict as Map
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
import System.IO (hGetContents)
import System.Process
  ( CreateProcess (..)
  , StdStream (..)
  , proc
  , readCreateProcessWithExitCode
  , shell
  , withCreateProcess
  , waitForProcess
  , terminateProcess
  , interruptProcessGroupOf
  )
import System.Timeout (timeout)

import Harness.Alphabet (Call (..), Obs, inline, obsRender, obsRef)
import Harness.Ref (Store, absorbWith, selector)
import Harness.Preview (previewThreshold, scrapeThreshold)
import Harness.Schema (keySynonyms)

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
  result <- try (dispatch root (T.unpack (tool c)) (parseArgs (T.unpack (args c))))
  pure $ inline $ T.pack $ case result of
    Left (e :: SomeException) -> "error: " ++ show e
    Right out                 -> out

-- | Decorate a base world with the reference store. Selector calls
-- (@jsonpath@\/@deref@) are resolved from the store; every other result is
-- thresholded — parked under a ref and previewed when large, passed through
-- inline when small. Keeps large tool output out of the transcript so the
-- model's context stays small while the full value remains retrievable. The
-- store is per-run mutable state owned here at the IO boundary; the decisions
-- are the pure 'Harness.Ref' functions. [design]
refWorld :: IORef Store -> (Call -> IO Obs) -> Call -> IO Obs
refWorld ref base c
  | tool c `elem` ["jsonpath", "deref"] =
      atomicModifyIORef' ref (\st -> swap (selector c st))
  | otherwise = do
      o <- base c
      atomicModifyIORef' ref (\st -> swap (absorbWith (parkThreshold (tool c)) o st))
  where
    swap (a, b) = (b, a)
    -- Per-tool park policy: a web fetch is parked eagerly (pages are large and
    -- navigable, and several would otherwise accumulate inline past the window),
    -- every other tool keeps the generous default that leaves ordinary files
    -- inline. See 'Harness.Preview.scrapeThreshold'. [design]
    parkThreshold "scrape_url" = scrapeThreshold
    parkThreshold _            = previewThreshold

-- | Decorate a base world so that re-reading an __unchanged__ file does not
-- re-append its full content to the transcript. The first @read@ of a path
-- returns the real result; a later @read@ of the same path whose content is
-- byte-identical returns a short note instead, telling the model it already has
-- the file and should not fetch it again.
--
-- __Why this exists.__ A weak model will, for some task phrasings, re-issue an
-- identical @read@ of a file it has just read rather than acting on it (observed:
-- @qwen3:8b@ re-reads a just-read 9 KB README ~100% of the time for
-- \"read X, summarise it, overwrite Y\"). Each re-read re-appends the whole file,
-- so the context grows a file-width per turn and overflows @num_ctx@ in a few
-- turns — a run-ending 'Harness.Alphabet.Overflow' driven entirely by the model
-- spinning. Collapsing the redundant re-read to a one-line note removes the
-- amplification (the transcript no longer grows) and, by naming the redundancy,
-- usually breaks the spin as well. It is the idempotent-read dual of 'refWorld':
-- @refWorld@ keeps a /large/ result out of the transcript; this keeps a
-- /repeated/ result out of it. [established]
--
-- __Scope, deliberately narrow.__ Only @read@ is guarded (the one idempotent,
-- 'Harness.State.ReplaySafe' file tool), and only when its result came back
-- /inline/: a result 'refWorld' already parked under a reference is a small
-- preview that cannot overflow anything, so it is passed through untouched.
-- Sameness is judged on the returned render, so a file a prior @write@ changed
-- reads fresh (its render differs) and is returned in full. The per-run memory
-- is an 'IORef' owned at the IO boundary, mirroring 'refWorld'\'s store. [design]
--
-- __Caveat after compaction.__ The memory is not cleared when the transcript is
-- compacted to a 'Harness.State.Summary', so a re-read following a compaction is
-- still collapsed even though the file's full text is no longer literally
-- \"above\" — only its summary is. This is the intended outcome regardless: after
-- compaction the model /should/ work from the summary rather than re-flood the
-- context with the whole file, which is exactly what the note steers it to do.
-- [design]
onceReadWorld :: IORef (Map.Map T.Text T.Text) -> (Call -> IO Obs) -> Call -> IO Obs
onceReadWorld ref base c
  | tool c == "read" = do
      o <- base c
      case obsRef o of
        Just _  -> pure o   -- already parked by refWorld: a small preview, cannot overflow
        Nothing -> do
          let path = readPath c
          seen <- readIORef ref
          case Map.lookup path seen of
            Just prev | prev == obsRender o -> pure (inline (alreadyRead path))
            _ -> do
              atomicModifyIORef' ref (\m -> (Map.insert path (obsRender o) m, ()))
              pure o
  | otherwise = base c
  where
    -- Normalise through the same synonym lattice the dispatcher uses, so
    -- @{"path":…}@ and @{"file":…}@ collapse to one key; fall back to the raw
    -- argument text when no path key is present.
    readPath call =
      maybe (args call) T.pack
        (arg (map T.unpack (keySynonyms "path")) (parseArgs (T.unpack (args call))))
    alreadyRead path =
      "already read " <> path <> " earlier in this run; its content is already "
        <> "in the conversation above. Do not read it again \8212 use what you "
        <> "have and continue the task."

-- ---------------------------------------------------------------------------
-- Dispatch
-- ---------------------------------------------------------------------------

-- | Route a call to the tool that runs it, pulling each tool's argument out of
-- the (loosely-keyed) 'Args' by trying every plausible key name the model might
-- have used. An unknown tool name is a recoverable error string, not a crash.
--
-- __Shell is absent here by design.__ @bash@ is refused by default; call
-- 'trustedShellWorld' instead of 'sandboxAct' when you want shell capability.
-- This means a caller cannot accidentally enable shell by passing a @bash@ call
-- through the default world — the opt-in must be explicit. [design]
dispatch :: FilePath -> String -> Args -> IO String
dispatch root tl a = case tl of
  "read"   -> readTool root (arg (map T.unpack (keySynonyms "path")) a)
  "write"  -> writeTool root (arg (map T.unpack (keySynonyms "path")) a)
                             (arg (map T.unpack (keySynonyms "body")) a)
  "commit" -> commitTool root (arg (map T.unpack (keySynonyms "msg")) a)
  "bash"   -> pure "error: shell disabled (use trustedShellWorld to opt in)"
  other    -> pure ("error: unknown tool " ++ other)

-- | @read@: return the raw file body. Path-confined through @withSafePath@; a
-- missing path or missing file is a plain error string. The raw body is
-- returned without decoration or clipping so that a parked JSON file remains
-- valid JSON that @jsonpath@ can navigate; the 'refWorld' decorator handles
-- size thresholding before the result enters the transcript.
readTool :: FilePath -> Maybe String -> IO String
readTool _ Nothing = pure "error: read: no path argument"
readTool root (Just rel) = withSafePath root rel $ \p -> do
  ok <- doesFileExist p
  if not ok
    then pure ("error: no such file: " ++ rel)
    else readFile p

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

-- | An opt-in world that adds the untrusted shell capability to 'sandboxAct'.
--
-- __This is not a security boundary.__ @trustedShell@ runs arbitrary commands
-- with the harness's own uid; @cwd@-confinement is not containment. Use only
-- with a trusted model, or wait for the microVM sandbox (see the @..\/scape@
-- project). [unbuilt: real isolation]
--
-- All non-@bash@ calls are forwarded to 'sandboxAct' unchanged, so this world
-- is a strict superset of the default one.
trustedShellWorld :: FilePath -> Call -> IO Obs
trustedShellWorld root c
  | tool c == "bash" = do
      result <- try (trustedShell root (arg ["cmd", "command", "script"] (parseArgs (T.unpack (args c)))))
      pure $ inline $ T.pack $ case result of
        Left (e :: SomeException) -> "error: " ++ show e
        Right out                 -> out
  | otherwise = sandboxAct root c

-- | Run a shell command in a new process group so a timeout can terminate the
-- whole tree, not merely stop waiting on it.
--
-- __Stdout\/stderr.__ We merge stderr into stdout via the shell (@2>&1@) rather
-- than draining two pipes concurrently. Two-pipe concurrent draining without a
-- dedicated thread per handle is prone to deadlock when either pipe fills its
-- kernel buffer before the other is read; the @2>&1@ merge avoids that entirely
-- with no observable difference to the model. [design]
--
-- __Kill caveats — best effort only.__
--
-- [speculative] If the child survives SIGTERM (e.g. it catches or blocks the
-- signal), the @waitForProcess@ inside @withCreateProcess@'s cleanup bracket
-- can block indefinitely, holding the harness thread.
--
-- [design] The SIGTERM escalation (@terminateProcess@) targets only the group
-- leader, not the entire process group. A group member that survived the
-- preceding SIGINT (@interruptProcessGroupOf@) can therefore be orphaned and
-- continue running after this function returns. Sending SIGKILL to the whole
-- group (@kill -9 -<pgid>@) would close the window, but the @process@ library
-- does not expose @signalProcessGroup@; the POSIX call would require @unix@
-- directly. This is the correct future fix. [unbuilt: SIGKILL-to-group via unix]
--
-- [speculative] For output-heavy commands, draining the pipe (@length out@
-- forcing the lazy 'hGetContents') happens inside the 10 s timeout window. A
-- command that exits quickly but emits hundreds of MB of output can therefore
-- exhaust the timeout during the drain phase and be misreported as timed out
-- rather than as producing too much output.
--
-- __Still not a security boundary__ — see 'trustedShellWorld'.
trustedShell :: FilePath -> Maybe String -> IO String
trustedShell _ Nothing = pure "error: bash: no command argument"
trustedShell root (Just cmd)
  | null cmd  = pure "error: bash: empty command"
  | otherwise = do
      -- Merge stderr into stdout to avoid two-pipe deadlock. [design]
      let cp = (shell (cmd ++ " 2>&1"))
                 { cwd          = Just root
                 , create_group = True
                 , std_out      = CreatePipe
                 }
      withCreateProcess cp $ \_ mout _ ph -> do
        out <- maybe (pure "") hGetContents mout
        mcode <- timeout (10 * 1000000) (length out `seq` waitForProcess ph)
        case mcode of
          Just code -> pure ("bash " ++ showExit code ++ "\n" ++ out)
          Nothing   -> do
            interruptProcessGroupOf ph
            _ <- timeout (2 * 1000000) (waitForProcess ph)
            terminateProcess ph
            pure "error: bash: timed out after 10s (process group killed)"

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

-- | Truncate long text for single-line summaries (e.g. commit output via 'firstLine').
clip :: Int -> String -> String
clip n s
  | length s <= n = s
  | otherwise     = take n s ++ "… [+" ++ show (length s - n) ++ " chars]"

firstLine :: String -> String
firstLine = clip 200 . takeWhile (/= '\n')
