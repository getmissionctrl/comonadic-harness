{-# LANGUAGE OverloadedStrings #-}

-- | An instrumented run of Harness.hs.
module Run where

import Data.IORef
import Data.List (intercalate)
import Harness

--------------------------------------------------------------------------------
-- A scripted oracle. Four turns: look around, write, commit, finish.

scriptedOracle :: IORef Int -> Prompt -> IO Response
scriptedOracle ref _ = do
    n <- readIORef ref
    writeIORef ref (n + 1)
    pure $ case n of
        0 -> Response "orienting" [Call "read" "README.md", Call "bash" "ls"]
        1 -> Response "editing" [Call "write" "notes.md"]
        2 -> Response "landing" [Call "commit" "wip"]
        _ -> Response "finished" []

realWorld :: Call -> IO Obs
realWorld c = pure (Obs (take 12 (tool c ++ ":" ++ args c)))

-- A deliberately imperfect model of that oracle. It assumes every turn
-- writes, and that the session ends once the prompt exceeds four lines.
hypo :: Hypo
hypo =
    Hypo
        { guessOracle = \(Prompt p) ->
            if length (lines p) > 4
                then Response "done" []
                else Response "guessing" [Call "write" "guess.txt"]
        , guessWorld = \c -> Obs (tool c)
        }

--------------------------------------------------------------------------------
-- Walk a real run, printing the annotation and the counterfactual gate at
-- every node before performing anything.

runVerbose :: Env IO -> Hypo -> Int -> Cofree HarnessF Ctx -> IO Outcome
runVerbose env h horizon = go (0 :: Int)
  where
    go i w@(c :< f) = do
        let Prompt p = ctxPrompt c
            r = assess h horizon w
        putStrLn $
            pad 3 (show i)
                ++ " budget="
                ++ pad 2 (show (ctxBudget c))
                ++ "  ctx="
                ++ pad 2 (show (length (lines p)))
                ++ "ln"
                ++ "  tools="
                ++ pad 24 (intercalate "," (ctxTools c))
                ++ "  risk="
                ++ pad 5 (show (steps r) ++ "/" ++ (if terminates r then "T" else "-"))
                ++ " irrev="
                ++ show (map tool (irreversible r))
        case f of
            Halt o -> do
                putStrLn ("    HALT " ++ show o)
                pure o
            Render q k -> do
                resp <- oracle env q
                putStrLn ("    RENDER -> " ++ say resp ++ " " ++ show (map tool (calls resp)))
                go (i + 1) (k resp)
            Perform call k -> do
                o <- world env call
                let Obs t = o
                putStrLn ("    PERFORM " ++ tool call ++ "(" ++ args call ++ ") -> " ++ t)
                go (i + 1) (k o)

pad :: Int -> String -> String
pad n s = s ++ replicate (n - length s) ' '

--------------------------------------------------------------------------------
-- Compaction: a state with some history, and its compacted image.

sampleS :: S
sampleS =
    S
        { transcript =
            [ User [(Call "read" "d", Obs "ok")]
            , Assistant (Response "again" [Call "read" "d"])
            , User [(Call "read" "c", Obs "ok")]
            , Assistant (Response "still" [Call "read" "c"])
            , User [(Call "read" "b", Obs "ok")]
            , Assistant (Response "more" [Call "read" "b"])
            , User [(Call "bash" "ls", Obs "ok")]
            , Assistant (Response "start" [Call "bash" "ls"])
            ]
        , pending = []
        , budget = 6
        }

--------------------------------------------------------------------------------
-- A coalgebra that never halts cleanly: it ignores empty tool-call lists
-- and never spends budget, so probing it finds no terminal state.

loopyStep :: S -> HarnessF S
loopyStep s = case pending s of
    (c : cs) ->
        Perform c $ \o ->
            s{transcript = record c o (transcript s), pending = cs}
    [] ->
        Render (project s) $ \r ->
            s{transcript = Assistant r : transcript s, pending = calls r}
  where
    record c o (User rs : ts) = User (rs ++ [(c, o)]) : ts
    record c o ts = User [(c, o)] : ts

--------------------------------------------------------------------------------

banner :: String -> IO ()
banner s = putStrLn ("\n== " ++ s ++ " " ++ replicate (60 - length s) '=')

demo :: IO ()
demo = do
    banner "1. the annotation at the root, before anything runs"
    let w0 = harness (S [] [] 8)
    print (extract w0)

    banner "2. counterfactual assessment, no effects performed"
    print (assess hypo 32 w0)
    print (probe hypo 32 w0)

    banner "3. governed: extend attaches that assessment to every node"
    let g = governed hypo 32 w0
    putStrLn ("here:       " ++ show (extract g))
    case g of
        _ :< Render _ k -> do
            let g1 = k (Response "guessing" [Call "write" "guess.txt"])
            putStrLn ("if it writes: " ++ show (extract g1))
            case g1 of
                _ :< Perform _ k2 ->
                    putStrLn ("after that:   " ++ show (extract (k2 (Obs "write"))))
                _ -> pure ()
        _ -> pure ()

    banner "4. the real run"
    ref <- newIORef 0
    let env = Env{oracle = scriptedOracle ref, world = realWorld}
    o <- runVerbose env hypo 32 w0
    putStrLn ("outcome: " ++ show o)

    banner "5. compaction is not a coalgebra homomorphism"
    putStrLn ("before:  " ++ show (probe hypo 12 (harness sampleS)))
    putStrLn ("after:   " ++ show (probe hypo 12 (harness (compact sampleS))))
    putStrLn ("respects behaviour? " ++ show (respectsBehaviour hypo 12 compact sampleS))

    banner "6. evolution: reject a coalgebra whose future has no exit"
    let loopy = evolve view loopyStep (S [] [] 8)
    putStrLn ("loopy:  " ++ show (assess hypo 32 loopy))
    putStrLn ("good:   " ++ show (assess hypo 32 w0))
    ref2 <- newIORef 0
    let env2 = Env{oracle = scriptedOracle ref2, world = realWorld}
    o2 <- outerLoop env2 hypo [(view, loopyStep), (view, step)] (S [] [] 8)
    putStrLn ("outerLoop picked the fallback, outcome: " ++ show o2)

main :: IO ()
main = demo
