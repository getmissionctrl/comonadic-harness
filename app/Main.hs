-- | Demo entry point for the comonadic harness.
--
-- Default (@cabal run demo@): reproduces the recorded reference trace in
-- @runs\/oracle-output.txt@ using a fake oracle and world.
--
-- @cabal run demo live@: runs against the real Ollama provider on hq with a
-- small @num_ctx@ (512) to try to provoke the Summarising compaction.
module Main (main) where

import Control.Comonad.Cofree (Cofree ((:<)))
import Data.Monoid (Any (..), Sum (..))
import Harness.Alphabet
import Harness.Coalgebra (harness)
import Harness.Probe (Hypo (..), Risk (..), assess, probe)
import Harness.Run (Env (..), run)
import Harness.State (Ctx (..), Mode (..), S (..))
import Provider.Class (providerEnv)
import Provider.Ollama (OllamaCfg (..), defaultOllamaCfg, ollamaProvider)
import System.Environment (getArgs)

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
                putStrLn ("    PERFORM " ++ tool call ++ " -> " ++ t)
                go (i + 1) (k o)
            Render q k -> do
                resp <- oracle env q
                case resp of
                    Left e -> putStrLn ("    ORACLE refused: " ++ show e)
                    Right x ->
                        putStrLn
                            ( "    ORACLE "
                                ++ show (inTok (usage x) + outTok (usage x))
                                ++ "tok -> "
                                ++ say x
                                ++ " "
                                ++ show (map tool (calls x))
                            )
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

live :: IO ()
live = do
    let cfg = defaultOllamaCfg { ocNumCtx = 512 }
        env = providerEnv (ollamaProvider cfg)
    o <- run env (harness start)
    putStrLn ("live outcome: " ++ show o)

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

main :: IO ()
main = do
    args <- getArgs
    case args of
        ("live" : _) -> live
        _            -> demoFake
