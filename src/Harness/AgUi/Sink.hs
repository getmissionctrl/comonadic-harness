-- | The event 'Sink' (an @'AgUiEvent' -> IO ()@), two concrete sinks (an
-- in-memory STM log for live SSE fan-out and replay, and a JSONL file appender
-- for durability), and the tracing 'Env' decorator that emits AG-UI events
-- around a run's oracle and world calls.
--
-- This is the __only__ place execution meets AG-UI. The pure core never mentions
-- it: 'traceEnv' wraps an existing 'Env' from the outside, translating each
-- oracle reply and world observation into events via the pure builders
-- ('Harness.AgUi.Translate'). Emission is a decorator on the 'Env' seams, in the
-- spirit of invariant 5 (transient concerns decorate the environment) — it adds
-- no case to the alphabet and reads no annotation.
module Harness.AgUi.Sink
  ( Sink
  , EventLog
  , newEventLog
  , logSink
  , readFrom
  , jsonlSink
  , traceEnv
  , initRunState
  , initRunStateFor
  ) where

import Control.Concurrent.STM
import Control.Monad (unless)
import Data.Aeson (encode)
import qualified Data.ByteString.Lazy.Char8 as BL
import Harness.Run (Env (..))
import Harness.AgUi.Event
import Harness.AgUi.Translate

-- | Where a translated event goes. An @IO@ action so a sink can append to an STM
-- log, write a line to a file, push to a socket, or fan out to several at once.
type Sink = AgUiEvent -> IO ()

-- | An append-only in-memory event log: the backbone both live SSE subscribers
-- and late joiners (who replay from a cursor) read from. Append-only so a cursor
-- is just an index and no event is ever missed or mutated.
newtype EventLog = EventLog (TVar [AgUiEvent])

-- | A fresh, empty 'EventLog'.
newEventLog :: IO EventLog
newEventLog = EventLog <$> newTVarIO []

-- | A 'Sink' that appends to an 'EventLog'.
logSink :: EventLog -> Sink
logSink (EventLog v) e = atomically (modifyTVar' v (++ [e]))

-- | Block until the log holds more than @n@ events, then return the suffix from
-- index @n@ and the new length. An SSE handler loops on this: send the suffix,
-- advance its cursor, repeat. Never misses events and supports many concurrent
-- subscribers, because each keeps its own cursor and the log is append-only.
readFrom :: EventLog -> Int -> STM ([AgUiEvent], Int)
readFrom (EventLog v) n = do
  es <- readTVar v
  let len = length es
  unless (len > n) retry
  pure (drop n es, len)

-- | A 'Sink' that appends one JSON line per event to a file (JSONL) — the
-- durable record, so a run's event stream survives process exit and can be
-- replayed offline.
jsonlSink :: FilePath -> Sink
jsonlSink fp e = BL.appendFile fp (encode e <> "\n")

-- | Wrap an inner 'Env' so every oracle reply and world observation is
-- translated to AG-UI events and pushed to the 'Sink', with the shared
-- 'RunState' (budget, mode, ids) threaded through a 'TVar' so ids stay stable
-- and state deltas accurate across concurrent emission. The inner 'Env' supplies
-- the actual behaviour (a live provider, or the suspendable human env).
traceEnv :: Sink -> TVar RunState -> Env IO -> Env IO
traceEnv sink stVar inner = Env
  { oracle = \q -> do
      r <- oracle inner q
      case r of
        Left ref   -> emit (refusalEvents ref) >> pure r
        Right resp -> emit (oracleEvents resp) >> pure r
  , world = \c -> do
      o <- world inner c
      emit (worldEvents o)
      pure o
  }
  where
    emit f = do
      evs <- atomically $ do
        st <- readTVar stVar
        let (evs, st') = f st
        writeTVar stVar st'
        pure evs
      mapM_ sink evs
