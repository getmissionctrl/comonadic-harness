{-# LANGUAGE DeriveFunctor #-}

-- | Where the LLM actually lives.
--
-- Three amendments to Harness.hs, each forced by a real provider:
--
--   1. 'Render' carries a 'Request', not a 'Prompt'. The mode-dependent
--      affordances have to reach the provider; in Harness.hs they were
--      computed into the annotation and then silently dropped.
--
--   2. The continuation takes @Either Refusal Response@. Transient
--      failures stay inside Env (retry, backoff). Terminal ones must be
--      visible to the coalgebra, because 'Overflow' triggers a state
--      transition and the coalgebra is the only thing that can make one.
--
--   3. Budget is spent in tokens reported by the provider, not in turns.
--
-- The payoff: compaction needs a summarisation call, and it goes through
-- the same single 'Render' constructor. The alphabet does not grow. What
-- distinguishes a task turn from a summarisation turn is a mode bit in
-- the state, which is exactly the mode-dependence the design already had.

module Oracle where

import Harness (Cofree (..), extend, extract, unfold)

--------------------------------------------------------------------------------
-- 1. The wire types.

newtype Prompt = Prompt String deriving (Eq, Show)

data ToolSpec = ToolSpec {specName :: String, specSchema :: String}
    deriving (Eq, Show)

data Request = Request {reqPrompt :: Prompt, reqTools :: [ToolSpec]}
    deriving (Eq, Show)

data Call = Call {tool :: String, args :: String} deriving (Eq, Show)

newtype Obs = Obs String deriving (Eq, Show)

data Usage = Usage {inTok :: Int, outTok :: Int} deriving (Eq, Show)

data Response = Response {say :: String, calls :: [Call], usage :: Usage}
    deriving (Eq, Show)

-- | Failures the coalgebra must see. Everything else (429, 5xx, socket
-- timeouts, transient decode noise) is Env's problem and never gets here.
data Refusal
    = Overflow
    | Malformed String
    deriving (Eq, Show)

data Outcome = Done String | Exhausted | Stuck String deriving (Eq, Show)

data HarnessF x
    = Render Request (Either Refusal Response -> x)
    | Perform Call (Obs -> x)
    | Halt Outcome
    deriving (Functor)

--------------------------------------------------------------------------------
-- 2. State. The mode bit is what lets one constructor serve two purposes.

data Mode = Working | Summarising deriving (Eq, Show)

data Turn
    = Assistant Response
    | User [(Call, Obs)]
    | Summary String
    deriving (Eq, Show)

data S = S
    { transcript :: [Turn] -- newest first
    , pending :: [Call]
    , budget :: Int -- tokens, not turns
    , mode :: Mode
    }
    deriving (Eq, Show)

data Ctx = Ctx {ctxRequest :: Request, ctxBudget :: Int, ctxMode :: Mode}
    deriving (Eq, Show)

project :: S -> Prompt
project s = Prompt (unlines (map render (reverse (transcript s))))
  where
    render (Assistant r) = "A: " ++ say r ++ concatMap (\c -> " <" ++ tool c ++ ">") (calls r)
    render (User rs) = "U: " ++ concatMap (\(c, Obs o) -> tool c ++ "=" ++ o ++ " ") rs
    render (Summary t) = "S: " ++ t

allTools :: [ToolSpec]
allTools =
    [ ToolSpec "read" "{path:string}"
    , ToolSpec "bash" "{cmd:string}"
    , ToolSpec "write" "{path:string,body:string}"
    , ToolSpec "commit" "{msg:string}"
    ]

-- | Mode-dependent affordances, now actually reaching the provider.
afford :: S -> [ToolSpec]
afford s
    | mode s == Summarising = [] -- no tools during summarisation
    | any wrote (transcript s) = allTools
    | otherwise = filter ((/= "commit") . specName) allTools
  where
    wrote (User rs) = any ((== "write") . tool . fst) rs
    wrote _ = False

request :: S -> Request
request s = case mode s of
    Working -> Request (project s) (afford s)
    Summarising ->
        let Prompt p = project s
         in Request (Prompt (p ++ "\n[summarise the above in one line]")) []

view :: S -> Ctx
view s = Ctx (request s) (budget s) (mode s)

--------------------------------------------------------------------------------
-- 3. The coalgebra. One Render constructor, two jobs.

step :: S -> HarnessF S
step s
    | budget s <= 0 = Halt Exhausted
    | otherwise = case pending s of
        (c : cs) ->
            Perform c $ \o ->
                s{transcript = record c o (transcript s), pending = cs}
        [] -> case (mode s, transcript s) of
            (Working, Assistant r : _)
                | null (calls r) -> Halt (Done (say r))
            (Working, _) -> Render (request s) (working s)
            (Summarising, _) -> Render (request s) (summarising s)
  where
    record c o (User rs : ts) = User (rs ++ [(c, o)]) : ts
    record c o ts = User [(c, o)] : ts

working :: S -> Either Refusal Response -> S
working s (Left Overflow) = s{mode = Summarising}
working s (Left (Malformed m)) = s{transcript = Summary ("!" ++ m) : transcript s, budget = 0}
working s (Right r) =
    s
        { transcript = Assistant r : transcript s
        , pending = calls r
        , budget = budget s - inTok (usage r) - outTok (usage r)
        }

summarising :: S -> Either Refusal Response -> S
summarising s (Left _) = s{budget = 0}
summarising s (Right r) =
    s
        { transcript = [Summary (say r)]
        , mode = Working
        , budget = budget s - inTok (usage r) - outTok (usage r)
        }

harness :: S -> Cofree HarnessF Ctx
harness = unfold view step

--------------------------------------------------------------------------------
-- 4. Running. The provider seam, and nothing else.

data Env m = Env
    { oracle :: Request -> m (Either Refusal Response)
    , world :: Call -> m Obs
    }

run :: Monad m => Env m -> Cofree HarnessF Ctx -> m Outcome
run env (_ :< f) = case f of
    Halt o -> pure o
    Render q k -> oracle env q >>= run env . k
    Perform c k -> world env c >>= run env . k

--------------------------------------------------------------------------------
-- 5. What a real oracle looks like.
--
-- The HTTP client and the JSON codec are injected, so this module stays
-- base-only. In practice 'post' is http-client and 'decode' is aeson.
-- Note that retry is NOT here: it is a decorator on Env, below.

data Provider m = Provider
    { post :: String -> m String
    , decode :: String -> Either Refusal Response
    }

anthropicOracle :: Monad m => String -> Provider m -> Request -> m (Either Refusal Response)
anthropicOracle model p req = decode p <$> post p (encodeRequest model req)

-- | The affordances flowing into the payload. This is the amendment that
-- Harness.hs was missing: 'afford' was computed and then thrown away.
encodeRequest :: String -> Request -> String
encodeRequest model (Request (Prompt p) tools) =
    "{\"model\":"
        ++ str model
        ++ ",\"max_tokens\":4096"
        ++ ",\"messages\":[{\"role\":\"user\",\"content\":"
        ++ str p
        ++ "}]"
        ++ ",\"tools\":["
        ++ intercalate "," (map encodeTool tools)
        ++ "]}"
  where
    encodeTool (ToolSpec n sch) =
        "{\"name\":" ++ str n ++ ",\"input_schema\":" ++ str sch ++ "}"
    intercalate sep = foldr1 (\a b -> a ++ sep ++ b) . orEmpty
    orEmpty [] = [""]
    orEmpty xs = xs

str :: String -> String
str x = "\"" ++ concatMap esc x ++ "\""
  where
    esc '"' = "\\\""
    esc '\n' = "\\n"
    esc '\\' = "\\\\"
    esc ch = [ch]

-- | Transient failure handling lives here, not in the coalgebra.
withRetry :: Monad m => Int -> (Request -> m (Maybe (Either Refusal Response))) -> Env m -> Env m
withRetry n attempt env = env{oracle = go n}
  where
    go 0 _ = pure (Left (Malformed "retries exhausted"))
    go k q = do
        r <- attempt q
        case r of
            Just ok -> pure ok
            Nothing -> go (k - 1) q

--------------------------------------------------------------------------------
-- 6. Analysis still works, unchanged in shape.

data Hypo = Hypo
    { guessOracle :: Request -> Either Refusal Response
    , guessWorld :: Call -> Obs
    }

data Ev = Asked Mode | Refused Refusal | Did Call | Ended Outcome
    deriving (Eq, Show)

probe :: Hypo -> Int -> Cofree HarnessF Ctx -> [Ev]
probe _ 0 _ = []
probe h n w@(c :< f) = case f of
    Halt o -> [Ended o]
    Perform call k -> Did call : probe h (n - 1) (k (guessWorld h call))
    Render q k ->
        let r = guessOracle h q
            tag = case r of Left e -> [Refused e]; Right _ -> []
         in (Asked (ctxMode c) : tag) ++ probe h (n - 1) (k r)
  where
    _ = w

data Risk = Risk {stepsAhead :: Int, terminates :: Bool, irreversible :: [String], compactions :: Int}
    deriving (Eq, Show)

assess :: Hypo -> Int -> Cofree HarnessF Ctx -> Risk
assess h n w =
    Risk
        { stepsAhead = length evs
        , terminates = any ended evs
        , irreversible = [tool c | Did c <- evs, tool c `elem` ["write", "commit"]]
        , compactions = length [() | Refused Overflow <- evs]
        }
  where
    evs = probe h n w
    ended (Ended _) = True
    ended _ = False

governed :: Hypo -> Int -> Cofree HarnessF Ctx -> Cofree HarnessF Risk
governed h n = extend (assess h n)

--------------------------------------------------------------------------------
-- 7. A run in which the provider overflows and compaction happens through
--    the ordinary Render path.

fakeOracle :: Request -> IO (Either Refusal Response)
fakeOracle (Request (Prompt p) tools)
    | null tools = pure (Right (Response "worked on files, wrote notes, committed" [] (Usage 300 20)))
    | lns >= 5 = pure (Left Overflow)
    | lns == 0 = pure (Right (Response "orienting" [Call "read" "README.md"] (Usage 100 40)))
    | lns == 2 = pure (Right (Response "editing" [Call "write" "notes.md"] (Usage 140 40)))
    | otherwise = pure (Right (Response "landing" [Call "commit" "wip"] (Usage 160 40)))
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
                ++ show (stepsAhead r)
                ++ "/"
                ++ (if terminates r then "T" else "-")
                ++ " compactions="
                ++ show (compactions r)
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

start :: S
start = S [] [] 1200 Working

main :: IO ()
main = do
    putStrLn "== the request the provider actually receives ================"
    putStrLn (encodeRequest "claude-sonnet-4-6" (ctxRequest (extract (harness start))))
    putStrLn ""
    putStrLn "== counterfactual, before any call ==========================="
    print (assess hypo 40 (harness start))
    print (probe hypo 40 (harness start))
    putStrLn ""
    putStrLn "== the run ==================================================="
    o <- runVerbose (Env fakeOracle fakeWorld) hypo 40 (harness start)
    putStrLn ("outcome: " ++ show o)
