-- | Demo entry point for the comonadic harness.
--
-- Default (@cabal run demo@): reproduces the recorded reference trace in
-- @runs\/oracle-output.txt@ using a fake oracle and world.
--
-- @cabal run demo live [--model M] [--ctx N] your task words...@: runs against
-- the real Ollama provider on hq, printing the same annotated trace as the
-- scripted demo but driven by the live model. The trailing words become the
-- initial task (seeded as the opening transcript turn, so the first prompt is
-- non-empty); @--model@\/@--ctx@ tune the provider. Defaults: @qwen3:8b@,
-- @num_ctx@ 512 (small, to provoke the Summarising compaction), and a built-in
-- read\/write\/commit task. Example:
-- @cabal run demo live --ctx 4096 add a haskell function that reverses a list@.
module Main (main) where

import Control.Comonad.Cofree (Cofree ((:<)))
import Data.Monoid (Any (..), Sum (..))
import Harness.Alphabet
import Harness.Coalgebra (harness)
import Harness.Probe (Hypo (..), Risk (..), assess, probe)
import Harness.Run (Env (..))
import Harness.State (Ctx (..), Mode (..), S (..), Turn (..))
import Provider.Class (providerEnv)
import Provider.Ollama (OllamaCfg (..), defaultOllamaCfg, ollamaProvider)
import System.Environment (getArgs)
import Text.Read (readMaybe)

-- ---------------------------------------------------------------------------
-- Fake oracle / world (ported verbatim from reference/Oracle.hs §274-298)
-- ---------------------------------------------------------------------------

fakeOracle :: Request -> IO (Either Refusal Response)
fakeOracle (Request (Prompt p) tools)
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
        { guessOracle = \(Request (Prompt p) tools) ->
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

runVerbose :: Env IO -> Hypo -> Int -> Cofree HarnessF Ctx -> IO Outcome
runVerbose env h horizon = go (0 :: Int)
  where
    go i w@(c :< f) = do
        let Request (Prompt p) ts = ctxRequest c
            r = assess h horizon w
        putStrLn $
            pad 3 (show i)
                ++ " tok="
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
        case f of
            Halt o -> putStrLn ("    HALT " ++ show o) >> pure o
            Perform call k -> do
                o <- world env call
                let Obs t = o
                -- Show the raw args the model sent for this call — for a @write@
                -- that is the file body it actually proposed.
                putStrLn ("    PERFORM " ++ tool call ++ " " ++ args call ++ " -> " ++ t)
                go (i + 1) (k o)
            Render q k -> do
                resp <- oracle env q
                case resp of
                    Left e -> putStrLn ("    ORACLE refused: " ++ show e)
                    Right x -> do
                        putStrLn
                            ( "    ORACLE "
                                ++ show (inTok (usage x) + outTok (usage x))
                                ++ "tok -> "
                                ++ say x
                                ++ " "
                                ++ show (map tool (calls x))
                            )
                        -- Echo each proposed call with its JSON args, so the
                        -- model's generated content is visible, not just the
                        -- tool name.
                        mapM_
                            (\cl -> putStrLn ("      call " ++ tool cl ++ " args=" ++ args cl))
                            (calls x)
                go (i + 1) (k resp)

pad :: Int -> String -> String
pad n s = s ++ replicate (n - length s) ' '

-- ---------------------------------------------------------------------------
-- Initial state
-- ---------------------------------------------------------------------------

start :: S
start = S [] [] 1200 Working

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
    o <- runVerbose (Env fakeOracle fakeWorld) hypo 40 (harness start)
    putStrLn ("outcome: " ++ show o)

-- | Options for a live run, parsed from the args after @live@.
data LiveOpts = LiveOpts
    { loModel :: String
    , loCtx   :: Int
    , loTask  :: String
    }

-- | Parse @[--model M] [--ctx N] word...@: the recognised flags tune the
-- provider; every other argument is joined (on spaces) into the initial task.
-- Unknown or dangling flags simply fall through into the task text rather than
-- aborting — this is a demo, not a CLI to defend. A non-numeric @--ctx@ keeps
-- the default.
parseLive :: [String] -> LiveOpts
parseLive = go (LiveOpts (ocModel defaultOllamaCfg) 512 "")
  where
    go o ("--model" : m : rest) = go o { loModel = m } rest
    go o ("--ctx" : n : rest)   = go o { loCtx = maybe (loCtx o) id (readMaybe n) } rest
    go o (w : rest)             = go o { loTask = appendWord (loTask o) w } rest
    go o []                     = o
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
        env  = providerEnv (ollamaProvider cfg)
        seeded = start { transcript = [Summary task] }
    putStrLn
        ( "== live run: model=" ++ ocModel cfg
            ++ " numCtx=" ++ show (ocNumCtx cfg)
            ++ " @ " ++ ocBaseUrl cfg ++ " ================" )
    putStrLn ("task (seeded as the opening turn): " ++ task)
    putStrLn "(risk column is the harness's pure forecast; oracle lines are the live model)"
    result <- runVerbose env hypo 40 (harness seeded)
    putStrLn ("live outcome: " ++ show result)

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

main :: IO ()
main = do
    args <- getArgs
    case args of
        ("live" : rest) -> live rest
        _               -> demoFake
