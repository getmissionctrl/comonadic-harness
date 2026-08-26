{-# LANGUAGE DeriveFunctor #-}

-- | A minimal comonadic agentic harness.
--
-- Four moves:
--
--   1. A closed interface functor 'HarnessF' (the action alphabet).
--   2. A coalgebra @step :: S -> HarnessF S@ (what you implement).
--   3. 'unfold' into @Cofree HarnessF Ctx@ (what you reason about).
--   4. 'run' pairs the tree against an effectful environment.
--
-- The comonad is the denotation, not the implementation. You never build
-- the tree eagerly; it is an infinitely-branching lazy structure whose
-- branches are indexed by things you do not control.
--
-- Depends on base only.

module Harness where

--------------------------------------------------------------------------------
-- 0. Cofree, hand-rolled.

data Cofree f a = a :< f (Cofree f a)

infixr 5 :<

instance Functor f => Functor (Cofree f) where
    fmap g (a :< fs) = g a :< fmap (fmap g) fs

extract :: Cofree f a -> a
extract (a :< _) = a

duplicate :: Functor f => Cofree f a -> Cofree f (Cofree f a)
duplicate w@(_ :< fs) = w :< fmap duplicate fs

extend :: Functor f => (Cofree f a -> b) -> Cofree f a -> Cofree f b
extend g = fmap g . duplicate

-- | The only way to build a harness: an observation and a coalgebra.
-- This is the anamorphism. @view@ is the annotation, @next@ is the shape.
unfold :: Functor f => (s -> a) -> (s -> f s) -> s -> Cofree f a
unfold obs next s = obs s :< fmap (unfold obs next) (next s)

--------------------------------------------------------------------------------
-- 1. The alphabet. Closed, four constructors, no escape hatch.

newtype Prompt = Prompt String
    deriving (Eq, Show)

data Call = Call {tool :: String, args :: String}
    deriving (Eq, Show)

newtype Obs = Obs String
    deriving (Eq, Show)

data Response = Response {say :: String, calls :: [Call]}
    deriving (Eq, Show)

data Outcome = Done | Exhausted | Stuck String
    deriving (Eq, Show)

-- | The interface functor.
--
-- Positions are what the harness does; directions are what it does not
-- control. The harness is deterministic. All nondeterminism lives in the
-- function arguments, which is why 'duplicate' is pure and lazy.
data HarnessF x
    = Render Prompt (Response -> x)
    | Perform Call (Obs -> x)
    | Halt Outcome
    deriving (Functor)

--------------------------------------------------------------------------------
-- 2. State, and the three quotients on it.

data Turn
    = Assistant Response
    | User [(Call, Obs)]
    deriving (Eq, Show)

-- | Newest turn first.
data S = S
    { transcript :: [Turn]
    , pending :: [Call]
    , budget :: Int
    }
    deriving (Eq, Show)

-- | What is visible at a node. This is the annotation on the tree.
data Ctx = Ctx
    { ctxPrompt :: Prompt
    , ctxTools :: [String]
    , ctxBudget :: Int
    }
    deriving (Eq, Show)

-- | Quotient 1: project. Lossy, total, recomputed every turn.
project :: S -> Prompt
project s = Prompt (unlines (map render (reverse (transcript s))))
  where
    render (Assistant r) = "A: " ++ say r ++ concatMap (\c -> " <" ++ tool c ++ ">") (calls r)
    render (User rs) = "U: " ++ concatMap (\(c, Obs o) -> tool c ++ "=" ++ o ++ " ") rs

-- | Mode-dependent affordances. A fold over the transcript, not a constant.
-- This is why the interface is polynomial rather than a fixed product.
afford :: S -> [String]
afford s
    | any wrote (transcript s) = base ++ ["commit"]
    | otherwise = base
  where
    base = ["read", "bash", "write"]
    wrote (User rs) = any ((== "write") . tool . fst) rs
    wrote _ = False

view :: S -> Ctx
view s = Ctx (project s) (afford s) (budget s)

--------------------------------------------------------------------------------
-- 3. The coalgebra. This is the whole control flow of a coding agent.
--
-- Compare @naiveTilNoToolCallStep@ in agents-exe: same case analysis,
-- but returning a functor of successor states rather than an action to
-- be interpreted by a separate driver.

step :: S -> HarnessF S
step s
    | budget s <= 0 = Halt Exhausted
    | otherwise = case pending s of
        (c : cs) ->
            Perform c $ \o ->
                s{transcript = record c o (transcript s), pending = cs}
        [] -> case transcript s of
            (Assistant r : _)
                | null (calls r) -> Halt Done
            _ ->
                Render (project s) $ \r ->
                    s
                        { transcript = Assistant r : transcript s
                        , pending = calls r
                        , budget = budget s - 1
                        }
  where
    record c o (User rs : ts) = User (rs ++ [(c, o)]) : ts
    record c o ts = User [(c, o)] : ts

harness :: S -> Cofree HarnessF Ctx
harness = unfold view step

--------------------------------------------------------------------------------
-- 4. Running. The pairing of the tree against an effectful environment.
--
-- Note that @run@ never looks at the annotation. Execution uses the shape;
-- analysis uses the annotation. That separation is the point of the whole
-- construction.

data Env m = Env
    { oracle :: Prompt -> m Response
    , world :: Call -> m Obs
    }

run :: Monad m => Env m -> Cofree HarnessF Ctx -> m Outcome
run env (_ :< f) = case f of
    Halt o -> pure o
    Render p k -> oracle env p >>= run env . k
    Perform c k -> world env c >>= run env . k

--------------------------------------------------------------------------------
-- 5. Counterfactual analysis. This is what the comonad actually buys.
--
-- The tree branches on things you do not control, so you cannot fold it.
-- You can fold it under a *hypothesis*: a pure stand-in for the oracle and
-- the world. That collapses the branching to a path.

data Hypo = Hypo
    { guessOracle :: Prompt -> Response
    , guessWorld :: Call -> Obs
    }

data Ev = Asked | Did Call | Ended Outcome
    deriving (Eq, Show)

-- | Drive the harness purely, to a bounded depth.
probe :: Hypo -> Int -> Cofree HarnessF Ctx -> [Ev]
probe _ 0 _ = []
probe h n (_ :< f) = case f of
    Halt o -> [Ended o]
    Render p k -> Asked : probe h (n - 1) (k (guessOracle h p))
    Perform c k -> Did c : probe h (n - 1) (k (guessWorld h c))

data Risk = Risk
    { steps :: Int
    , terminates :: Bool
    , irreversible :: [Call]
    }
    deriving (Eq, Show)

assess :: Hypo -> Int -> Cofree HarnessF Ctx -> Risk
assess h n w =
    Risk
        { steps = length evs
        , terminates = any ended evs
        , irreversible = [c | Did c <- evs, tool c `elem` ["write", "commit"]]
        }
  where
    evs = probe h n w
    ended (Ended _) = True
    ended _ = False

-- | Every reachable state, annotated with a counterfactual assessment of
-- its own future. One line, because that is what 'extend' is for.
--
-- @extract (governed h 12 w)@ is the pre-action gate at the current node.
governed :: Hypo -> Int -> Cofree HarnessF Ctx -> Cofree HarnessF Risk
governed h n = extend (assess h n)

--------------------------------------------------------------------------------
-- 6. Compaction, and its correctness condition.
--
-- The law you want is that compaction is a coalgebra homomorphism:
--
--     step (compact s)  ==  fmap compact (step s)
--
-- You cannot check that directly: @HarnessF S@ contains functions. What you
-- can check is its observable shadow. Note that the prompts *must* differ
-- after compaction, so the equivalence is on the action trace with 'Asked'
-- opaque, not on the rendered context. Compaction is correct exactly when
-- it is invisible in what the agent does.

compact :: S -> S
compact s = s{transcript = keep (transcript s)}
  where
    keep ts = take 2 ts ++ [User []] -- stand-in for a summary turn

respectsBehaviour :: Hypo -> Int -> (S -> S) -> S -> Bool
respectsBehaviour h n k s =
    probe h n (harness (k s)) == probe h n (harness s)

--------------------------------------------------------------------------------
-- 7. Evolution: the outer loop.
--
-- Changing the coalgebra cannot be a constructor of 'HarnessF', because the
-- functor must not mention S. (This is exactly the wall agents-exe hits with
-- its @Evolve (Agent r)@ constructor, which is why forking there would need
-- a joining function and would break the Functor instance.)
--
-- Instead: evolution is fold-then-reunfold. Destruction, then creation.

evolve ::
    (S -> Ctx) ->
    (S -> HarnessF S) ->
    S ->
    Cofree HarnessF Ctx
evolve = unfold

-- | A run that revises its own coalgebra when the counterfactual assessment
-- says the current one is not terminating. The trigger reads the future;
-- the revision replaces the machine.
outerLoop ::
    Monad m =>
    Env m ->
    Hypo ->
    [(S -> Ctx, S -> HarnessF S)] -> -- successively weaker fallbacks
    S ->
    m Outcome
outerLoop _ _ [] _ = pure (Stuck "no coalgebra left")
outerLoop env h ((v, k) : rest) s =
    let w = evolve v k s
     in if terminates (assess h 32 w)
            then run env w
            else outerLoop env h rest s

--------------------------------------------------------------------------------
-- 8. A smoke test with a stub oracle and world.

stubEnv :: Env IO
stubEnv =
    Env
        { oracle = \(Prompt p) ->
            pure $
                if length (lines p) > 4
                    then Response "done" []
                    else Response "working" [Call "read" "README.md"]
        , world = \c -> pure (Obs ("ok:" ++ tool c))
        }

stubHypo :: Hypo
stubHypo =
    Hypo
        { guessOracle = \(Prompt p) ->
            if length (lines p) > 4
                then Response "done" []
                else Response "working" [Call "write" "out.txt"]
        , guessWorld = \c -> Obs ("ok:" ++ tool c)
        }

start :: S
start = S [] [] 8

main :: IO ()
main = do
    let w = harness start
    print (ctxTools (extract w))
    print (assess stubHypo 32 w)
    print (probe stubHypo 12 w)
    print (respectsBehaviour stubHypo 12 compact start)
    o <- run stubEnv w
    print o
