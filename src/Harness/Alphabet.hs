{-# LANGUAGE DeriveAnyClass #-}

-- | The closed action alphabet. Three constructors, no escape hatch.
--
-- Positions are what the harness /does/; directions (the function
-- arguments) are what it does /not/ control. The harness is deterministic;
-- all nondeterminism lives in the directions, which is exactly why
-- 'Control.Comonad.Cofree.duplicate' on the unfolded tree is pure and lazy.
-- [established]
module Harness.Alphabet
  ( Prompt (..)
  , ToolSpec (..)
  , Request (..)
  , Call (..)
  , Obs (..)
  , Usage (..)
  , Response (..)
  , Refusal (..)
  , Outcome (..)
  , HarnessF (..)
  ) where

import GHC.Generics (Generic)

newtype Prompt = Prompt String
  deriving stock (Eq, Show, Generic)

-- | A tool the provider is told it may call. Carried in the 'Request' so it
-- actually reaches the model — the amendment 'reference/Harness.hs' lacked.
data ToolSpec = ToolSpec { specName :: String, specSchema :: String }
  deriving stock (Eq, Show, Generic)

-- | What the model sees: the projected prompt plus the mode-dependent tools.
data Request = Request { reqPrompt :: Prompt, reqTools :: [ToolSpec] }
  deriving stock (Eq, Show, Generic)

data Call = Call { tool :: String, args :: String }
  deriving stock (Eq, Show, Generic)

newtype Obs = Obs String
  deriving stock (Eq, Show, Generic)

-- | Token usage as reported by the provider. Budget is spent in tokens,
-- not turns. [established]
data Usage = Usage { inTok :: Int, outTok :: Int }
  deriving stock (Eq, Show, Generic)

data Response = Response { say :: String, calls :: [Call], usage :: Usage }
  deriving stock (Eq, Show, Generic)

-- | The only failures the coalgebra may see. Everything transient (429, 5xx,
-- socket timeouts, transient decode noise) is the provider's problem and never
-- gets here (invariant 5).
data Refusal = Overflow | Malformed String
  deriving stock (Eq, Show, Generic)

data Outcome = Done String | Exhausted | Stuck String
  deriving stock (Eq, Show, Generic)

-- | The interface functor. Closed. A fourth constructor requires a matching
-- case in 'Harness.Interp.interp' and the law tests, or @-Wincomplete-patterns@
-- will (correctly) fail the build.
data HarnessF x
  = Render Request (Either Refusal Response -> x)
  | Perform Call (Obs -> x)
  | Halt Outcome
  deriving stock (Functor, Generic)
