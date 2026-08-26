-- | The harness state @S@ and the three quotients on it:
-- @project@ (lossy, what the model sees), the affordance fold, and @view@
-- (the annotation placed on every tree node).
module Harness.State
  ( Mode (..)
  , Turn (..)
  , S (..)
  , Ctx (..)
  , project
  , allTools
  , afford
  , request
  , view
  , renderLine
  ) where

import GHC.Generics (Generic)
import Harness.Alphabet

data Mode = Working | Summarising
  deriving stock (Eq, Show, Generic)

data Turn
  = Assistant Response
  | User [(Call, Obs)]
  | Summary String
  deriving stock (Eq, Show, Generic)

-- | Newest turn first. @mode@ is the bit that lets one 'Render' constructor
-- serve both a task turn and a summarisation turn.
data S = S
  { transcript :: [Turn]
  , pending :: [Call]
  , budget :: Int      -- ^ tokens, not turns
  , mode :: Mode
  }
  deriving stock (Eq, Show, Generic)

-- | The annotation. Read by analysis (@probe@/@governed@), never used by
-- execution to choose a successor (invariant 2).
data Ctx = Ctx { ctxRequest :: Request, ctxBudget :: Int, ctxMode :: Mode }
  deriving stock (Eq, Show, Generic)

-- | Render one turn to a prompt line. Factored out so the prefix-stability
-- law (§16.6) can be stated: in 'Working' mode,
-- @project (t : ts) == project ts <> renderLine t@ (appending a turn appends
-- to the end of the prompt, leaving the cached prefix untouched). [established]
renderLine :: Turn -> String
renderLine (Assistant r) = "A: " ++ say r ++ concatMap (\c -> " <" ++ tool c ++ ">") (calls r)
renderLine (User rs)     = "U: " ++ concatMap (\(c, Obs o) -> tool c ++ "=" ++ o ++ " ") rs
renderLine (Summary t)   = "S: " ++ t

-- | Quotient 1. Lossy, total, recomputed each turn.
project :: S -> Prompt
project s = Prompt (unlines (map renderLine (reverse (transcript s))))

allTools :: [ToolSpec]
allTools =
  [ ToolSpec "read" "{path:string}"
  , ToolSpec "bash" "{cmd:string}"
  , ToolSpec "write" "{path:string,body:string}"
  , ToolSpec "commit" "{msg:string}"
  ]

-- | Mode-dependent affordances — a fold over the transcript, not a constant.
-- This is what makes the interface polynomial. @commit@ is only offered once
-- a @write@ has happened.
afford :: S -> [ToolSpec]
afford s
  | mode s == Summarising = []
  | any wrote (transcript s) = allTools
  | otherwise = filter ((/= "commit") . specName) allTools
  where
    wrote (User rs) = any ((== "write") . tool . fst) rs
    wrote _ = False

-- | In 'Summarising' mode the request carries a summarisation instruction and
-- /no tools/ — so compaction goes through the same 'Render' constructor.
request :: S -> Request
request s = case mode s of
  Working -> Request (project s) (afford s)
  Summarising ->
    let Prompt p = project s
     in Request (Prompt (p ++ "\n[summarise the above in one line]")) []

view :: S -> Ctx
view s = Ctx (request s) (budget s) (mode s)
