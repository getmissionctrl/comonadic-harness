-- | The single interpreter over the alphabet. Both 'Harness.Run.run' (in @IO@)
-- and 'Harness.Probe.probe' (pure, fuel-limited) are instances of it, so the
-- law that they agree is free by construction rather than maintained by
-- inspection across two hand-written case analyses (defect D9, §16.1).
--
-- The interpreter emits one 'Ev' per node into a 'Control.Monad.Writer' and
-- respects a depth bound. Both are monadic effects, not extra constructors.
-- Reading @Ctx@ here only /labels/ an event; the successor is always
-- @k result@, never a function of the annotation (invariant 2).
module Harness.Interp
  ( Ev (..)
  , interp
  ) where

import Control.Comonad.Cofree (Cofree ((:<)))
import Control.Monad.Writer (MonadWriter, tell)
import Harness.Alphabet
import Harness.State (Ctx (..), Mode)

-- | An observation of one interpreter step. @Asked@ carries the mode so the
-- summarisation turns are distinguishable in a trace.
data Ev = Asked Mode | Refused Refusal | Did Call | Ended Outcome
  deriving stock (Eq, Show)

-- | @interp askOracle askWorld fuel tree@ walks the tree, performing the
-- (possibly effectful) oracle/world actions, until it 'Halt's or runs out of
-- fuel. Returns @Just outcome@ on halt, @Nothing@ if fuel is exhausted first.
--
-- The three cases below are exhaustive and wildcard-free: adding a 'HarnessF'
-- constructor must break this build (invariant 1).
interp
  :: MonadWriter [Ev] m
  => (Request -> m (Either Refusal Response))
  -> (Call -> m Obs)
  -> Int
  -> Cofree HarnessF Ctx
  -> m (Maybe Outcome)
interp askOracle askWorld = go
  where
    go _ (_ :< Halt o) = Just o <$ tell [Ended o]
    go n _ | n <= 0 = pure Nothing
    go n (c :< Render q k) = do
      tell [Asked (ctxMode c)]
      r <- askOracle q
      case r of
        Left e  -> tell [Refused e]
        Right _ -> pure ()
      go (n - 1) (k r)
    go n (_ :< Perform call k) = do
      tell [Did call]
      o <- askWorld call
      go (n - 1) (k o)
