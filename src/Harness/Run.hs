{-# LANGUAGE ScopedTypeVariables #-}

-- | Running a harness: pair the tree against an effectful environment. @run@ is
-- @interp@ over the real oracle and world, in @WriterT@ over @IO@ with the
-- event trace discarded — execution consumes the shape, not the annotation.
module Harness.Run
  ( Env (..)
  , run
  ) where

import Control.Comonad.Cofree (Cofree)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Writer (runWriterT)
import Harness.Alphabet
import Harness.Interp (Ev, interp)
import Harness.State (Ctx)

-- | The provider seam and the world seam. The LLM lives in exactly one field.
data Env m = Env
  { oracle :: Request -> m (Either Refusal Response)
  , world  :: Call -> m Obs
  }

-- | Drive the harness to termination. Fuel is 'maxBound': a real run halts on
-- 'Halt', never on fuel. A @Nothing@ (fuel exhausted) is impossible here and
-- maps to @Stuck@ defensively.
run :: Env IO -> Cofree HarnessF Ctx -> IO Outcome
run env w = do
  (mo, _evs :: [Ev]) <-
    runWriterT (interp (\q -> lift (oracle env q)) (\c -> lift (world env c)) maxBound w)
  pure (maybe (Stuck "fuel exhausted") id mo)
