-- | The human-in-the-loop 'Env'. Its 'oracle' emits an "awaiting input" signal
-- and then blocks on an 'InputSlot' the transport fills from the client, turning
-- the pure 'Harness.Alphabet.Ask' suspension point into a real, resumable pause.
--
-- This is the payoff of putting nondeterminism in the /directions/: the harness
-- always knows it is at an 'Ask'; what it does not know is the reply. A human
-- supplying that reply is just another 'oracle' — the same field a live provider
-- occupies (invariant: the LLM, or here the human, lives in exactly one seam).
-- The 'world' seam is supplied by the caller (auto-run tools in v1; a blocking
-- approval world can be dropped in without touching the core).
module Harness.AgUi.HumanEnv
  ( InputSlot
  , newInputSlot
  , provideInput
  , humanEnv
  ) where

import Control.Concurrent.STM
import Harness.Alphabet
import Harness.Run (Env (..))

-- | A one-shot rendezvous for one pending oracle answer. The oracle takes from
-- it (blocking); the transport puts into it when the client responds. A 'TMVar'
-- so the take blocks cheaply and the put can be composed atomically with the
-- transport's own registry bookkeeping.
newtype InputSlot = InputSlot (TMVar (Either Refusal Response))

-- | A fresh, empty 'InputSlot'.
newInputSlot :: IO InputSlot
newInputSlot = InputSlot <$> newEmptyTMVarIO

-- | Fill the slot with the client's answer, unblocking the oracle. In 'STM' so
-- the transport handler can commit it together with other state atomically.
provideInput :: InputSlot -> Either Refusal Response -> STM ()
provideInput (InputSlot v) = putTMVar v

-- | Build a human-in-the-loop 'Env'. @announce@ runs (typically to push an
-- AG-UI "awaiting user message" event) immediately before the oracle blocks, so
-- a client knows input is required; then the oracle blocks on the 'InputSlot'
-- until 'provideInput' is called. The @world@ seam is passed straight through.
humanEnv
  :: (Request -> IO ())          -- ^ announce: signal that input is required
  -> InputSlot
  -> (Call -> IO Obs)            -- ^ world seam (auto or approval)
  -> Env IO
humanEnv announce (InputSlot v) w = Env
  { oracle = \q -> do
      announce q
      atomically (takeTMVar v)
  , world = w
  }
