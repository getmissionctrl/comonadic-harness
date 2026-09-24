-- | Demo entry point for the comonadic harness.
--
-- Default (@cabal run demo@): reproduces the recorded reference trace in
-- @runs\/oracle-output.txt@ using a fake oracle and world.
--
-- @cabal run demo live [--model M] [--ctx N] your task words...@: runs against
-- the real Ollama provider, printing the same annotated trace as the
-- scripted demo but driven by the live model. The trailing words become the
-- initial task (seeded as the opening transcript turn, so the first prompt is
-- non-empty); @--model@\/@--ctx@ tune the provider. Defaults: @qwen3:8b@,
-- @num_ctx@ 512 (small, to provoke the Summarising compaction), and a built-in
-- read\/write\/commit task. Example:
-- @cabal run demo live --ctx 4096 add a haskell function that reverses a list@.
module Main (main) where

import Control.Comonad.Cofree (Cofree ((:<)))
import Control.Monad.Except (runExceptT)
import Control.Monad.IO.Class (liftIO)
import Data.Monoid (Any (..), Sum (..))
import Harness.Alphabet
import Harness.Coalgebra (harness)
import Harness.Fault (ProviderError (..))
import Harness.Interp (interp)
import Harness.Probe (Hypo (..), Risk (..), assess, probe)
import Harness.Run (Env (..), Live, hoistEnv, runNoTrace)
import Harness.State (Ctx (..), Mode (..), S (..), Turn (..), allTools)
import Provider.Ollama (OllamaCfg (..), defaultOllamaCfg, ollamaOracle)
import Provider.Tools (prepareSandbox, sandboxAct)
import System.Environment (getArgs)
import Text.Read (readMaybe)

-- ---------------------------------------------------------------------------
-- Fake oracle / world (ported verbatim from reference/Oracle.hs §274-298)
-- ---------------------------------------------------------------------------

fakeOracle :: Request -> IO (Either Refusal Response)
fakeOracle (Request (Prompt p) tools _)
    | null tools = pure (Right (Response "worked on files, wrote notes, committed" [] (Usage 300 20)))
    | lns >= 5   = pure (Left Overflow)
    | lns == 0   = pure (Right (Response "orienting" [Call "read" "README.md"] (Usage 100 40)))
    | lns == 2   = pure (Right (Response "editing" [Call "write" "notes.md"] (Usage 140 40)))
    | otherwise  = pure (Right (Response "landing" [Call "commit" "wip"] (Usage 160 40)))
  where
    lns = length (lines p)

fakeWorld :: Call -> IO Obs
fakeWorld c = pure (Obs (tool c ++ ":ok"))

hypo :: Hypo
hypo =
    Hypo
        { guessOracle = \(Request (Prompt p) tools _) ->
            if null tools
                then Right (Response "summary" [] (Usage 300 20))
                else
                    if length (lines p) >= 5
                        then Left Overflow
                        else Right (Response "guess" [Call "write" "g.txt"] (Usage 120 40))
        , guessWorld = \c -> Obs (tool c)
        }

-- ---------------------------------------------------------------------------
-- Verbose runner (ported from reference/Oracle.hs §300-342, with Sum/Any fixes)
-- ---------------------------------------------------------------------------

-- | Drive the harness to termination against a live 'Env', printing an
-- annotated per-node trace as it goes.
--
-- __Why route through 'interp'.__ There is exactly one case-analysis over
-- 'HarnessF' that /drives/ a walk, and it is 'Harness.Interp.interp'
-- (invariant 1). 'runVerbose' does not walk the tree itself; it supplies the
-- interpreter's observer\/oracle\/world hooks and lets the one interpreter do
-- the walking. The observer only /prints/ (invariant 2) — it reads each node's
-- 'Ctx' annotation and the pure 'assess' forecast for the header line, but never
-- chooses a successor; the oracle\/world wrappers print the model reply and the
-- tool result as a side effect and then hand the plain result straight back.
-- The final outcome is printed by the caller, not here.
runVerbose :: Env Live -> Hypo -> Int -> Cofree HarnessF Ctx -> IO (Either ProviderError Outcome)
runVerbose env h horizon w = do
    res <- runNoTrace (runExceptT (interp onNode ora wld maxBound w))
    pure (fmap (maybe (Stuck "fuel exhausted") id) res)
  where
    -- The observer: label the node. It reads the annotation and the pure
    -- forecast for display only (invariant-2-legal, exactly like 'interp'
    -- reading 'ctxMode').
    onNode node@(c :< _) = liftIO (putStrLn (nodeLine c (assess h horizon node)))
    -- The oracle seam of the live 'Env', wrapped to print the model reply.
    ora q = do
        r <- oracle env q
        liftIO (printOracle r)
        pure r
    -- The world seam of the live 'Env', wrapped to print the tool result.
    wld call = do
        o <- world env call
        liftIO (printPerform call o)
        pure o

-- | The per-node header line: budget\/mode\/context-size\/afforded-tools plus
-- the pure 'Risk' forecast for the node's own future. Reads the node's 'Ctx'
-- annotation only — display, not control (invariant 2).
nodeLine :: Ctx -> Risk -> String
nodeLine c r =
    "tok="
        ++ pad 5 (show (ctxBudget c))
        ++ " mode="
        ++ pad 12 (show (ctxMode c))
        ++ " ctx="
        ++ pad 3 (show (length (lines p)) ++ "ln")
        ++ " tools="
        ++ pad 30 (show (map specName ts))
        ++ " risk="
        ++ show (getSum (stepsAhead r))
        ++ "/"
        ++ (if getAny (terminates r) then "T" else "-")
        ++ " compactions="
        ++ show (getSum (compactions r))
  where
    Request (Prompt p) ts _ = ctxRequest c

-- | Print the oracle reply for a 'Ask': a refusal, or the token count, the
-- model's @say@, and each proposed call with its raw args (so the generated
-- content is visible, not just the tool name).
printOracle :: Either Refusal Response -> IO ()
printOracle (Left e) = putStrLn ("    ORACLE refused: " ++ show e)
printOracle (Right x) = do
    putStrLn
        ( "    ORACLE "
            ++ show (inTok (usage x) + outTok (usage x))
            ++ "tok -> "
            ++ say x
            ++ " "
            ++ show (map tool (calls x))
        )
    mapM_
        (\cl -> putStrLn ("      call " ++ tool cl ++ " args=" ++ args cl))
        (calls x)

-- | Print the tool 'Call' actually run at a 'Perform' node with its raw args
-- (for a @write@ that is the file body the model proposed) and the resulting
-- 'Obs'.
printPerform :: Call -> Obs -> IO ()
printPerform call (Obs t) =
    putStrLn ("    PERFORM " ++ tool call ++ " " ++ args call ++ " -> " ++ t)

pad :: Int -> String -> String
pad n s = s ++ replicate (n - length s) ' '

-- ---------------------------------------------------------------------------
-- Initial state
-- ---------------------------------------------------------------------------

start :: S
start = S [] [] 1200 Working allTools

-- ---------------------------------------------------------------------------
-- Modes
-- ---------------------------------------------------------------------------

demoFake :: IO ()
demoFake = do
    -- (Omitted: the Anthropic encodeRequest JSON header from the reference.
    -- That section encoded a wire request for the Anthropic API; our stack
    -- targets Ollama so there is no equivalent encoder to call.)
    putStrLn "== counterfactual, before any call ==========================="
    print (assess hypo 40 (harness start))
    print (probe hypo 40 (harness start))
    putStrLn ""
    putStrLn "== the run ==================================================="
    res <- runVerbose (hoistEnv (Env fakeOracle fakeWorld)) hypo 40 (harness start)
    case res of
        Right o -> putStrLn ("outcome: " ++ show o)
        Left e  -> putStrLn ("provider error: " ++ show e)

-- | The sandbox the live run's tools operate in. @read@\/@write@\/@bash@\/
-- @commit@ are confined here (its own git repo); the surrounding project repo is
-- never touched.
sandboxDir :: FilePath
sandboxDir = "runs/agent-sandbox"

-- | Options for a live run, parsed from the args after @live@.
data LiveOpts = LiveOpts
    { loModel  :: String
    , loCtx    :: Int
    , loBudget :: Int
    , loTask   :: String
    }

-- | Parse @[--model M] [--ctx N] [--budget N] word...@: the recognised flags
-- tune the run; every other argument is joined (on spaces) into the initial
-- task. Unknown or dangling flags simply fall through into the task text rather
-- than aborting — this is a demo, not a CLI to defend. A non-numeric flag value
-- keeps the default.
parseLive :: [String] -> LiveOpts
parseLive = go (LiveOpts (ocModel defaultOllamaCfg) 512 6000 "")
  where
    go o ("--model" : m : rest)  = go o { loModel = m } rest
    go o ("--ctx" : n : rest)    = go o { loCtx = maybe (loCtx o) id (readMaybe n) } rest
    go o ("--budget" : n : rest) = go o { loBudget = maybe (loBudget o) id (readMaybe n) } rest
    go o (w : rest)              = go o { loTask = appendWord (loTask o) w } rest
    go o []                      = o
    appendWord ""  w = w
    appendWord acc w = acc ++ " " ++ w

-- | A default task when none is given, chosen to invite the read → write →
-- commit progression (recall @commit@ is only afforded once a @write@ has
-- happened, so this exercises the mode-dependent affordance fold).
defaultTask :: String
defaultTask = "Read the project README, write a one-line note summarising it, then commit."

-- | Drive the harness against the live Ollama provider, printing the full
-- annotated trace via 'runVerbose'. The initial task is /seeded/ as the opening
-- 'Summary' turn so the first prompt is non-empty (an empty prompt is what real
-- Ollama rejects). The @risk@ column is the harness's own /pure/ forecast under
-- 'hypo' (it never calls the model), shown beside what the real model actually
-- does — so you can watch the live run against the counterfactual.
live :: [String] -> IO ()
live args = do
    let o    = parseLive args
        task = if null (loTask o) then defaultTask else loTask o
        cfg  = defaultOllamaCfg { ocModel = loModel o, ocNumCtx = loCtx o }
        -- Real oracle (Ollama) + real sandboxed world (Provider.Tools), built
        -- directly in the 'Live' stack the interpreter walks in. 'ollamaOracle'
        -- is monad-polymorphic and so fits 'Live' as-is (a transport fault it
        -- raises rides the 'ExceptT' channel past the coalgebra, invariant 5);
        -- 'sandboxAct' is plain IO, lifted with 'liftIO'. There is no bundled
        -- no-op world (F6) — the world half is supplied explicitly here.
        env  = Env (ollamaOracle cfg) (liftIO . sandboxAct sandboxDir) :: Env Live
        seeded = start { transcript = [Summary task], budget = loBudget o }
    prepareSandbox sandboxDir "README.md"
    putStrLn
        ( "== live run: model=" ++ ocModel cfg
            ++ " numCtx=" ++ show (ocNumCtx cfg)
            ++ " budget=" ++ show (loBudget o)
            ++ " @ " ++ ocBaseUrl cfg ++ " ================" )
    putStrLn ("task (seeded as the opening turn): " ++ task)
    putStrLn ("sandbox: " ++ sandboxDir ++ " (tools run here; project repo untouched)")
    putStrLn "(risk column is the harness's pure forecast; oracle lines are the live model)"
    result <- runVerbose env hypo 40 (harness seeded)
    case result of
        Right outcome -> putStrLn ("live outcome: " ++ show outcome)
        Left (ProviderUnavailable e) ->
            putStrLn ("live run could not reach the provider: " ++ e)

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

main :: IO ()
main = do
    args <- getArgs
    case args of
        ("live" : rest) -> live rest
        _               -> demoFake
