-- | The /single/ interpreter over the alphabet, and the module that makes the
-- agreement law free.
--
-- __The load-bearing fact.__ There is exactly one function that @case@s over
-- 'HarnessF' to /run/ a harness, and it is 'interp'. Both @Harness.Run.run@ (in
-- @IO@, against a live model and a real world) and @Harness.Probe.probe@ (pure,
-- fuel-limited, against a 'Harness.Path.Hypo') are obtained by instantiating
-- 'interp' at different monads and different oracle\/world actions — not by
-- writing the walk twice. That is the whole point: if two functions both
-- interpreted the alphabet they would drift, and the law that they agree
-- (@run@ and @probe@ produce the same trace on the same inputs) is precisely
-- what this design exists to guarantee. Sharing one interpreter makes the law
-- true by construction rather than maintained by inspection (defect D9, §16.1).
--
-- __What the interpreter adds over the raw fold.__ It emits one 'Ev' per node
-- into a 'Control.Monad.Writer' (the trace) and respects a depth bound (the
-- fuel). Both are /monadic effects layered on top/, not extra 'HarnessF'
-- constructors — the alphabet stays closed at three.
--
-- __Invariant 2 stands here too.__ Reading the 'Ctx' annotation at a 'Ask'
-- node only /labels/ the emitted event (with the 'Harness.State.Mode'); it never
-- chooses the successor. The successor is always @k result@ — a function of the
-- oracle\/world /direction/, never of the annotation. Execution consumes the
-- shape; analysis consumes the annotation.
module Harness.Interp
  ( Ev (..)
  , interp
  ) where

import Control.Comonad.Cofree (Cofree ((:<)))
import Control.Monad.Except (MonadError)
import Control.Monad.Writer (MonadWriter, tell)
import Harness.Alphabet
import Harness.Fault (ProviderError)
import Harness.State (Ctx (..), Mode)

-- | A single observable event of one interpreter step — the unit of the trace
-- 'interp' writes. It exists so that a run (live or pure) leaves behind a
-- flat, comparable record of what happened, which is what the agreement law and
-- the demos compare. One 'Ev' is emitted per node visited; a whole run is a
-- @['Ev']@. [design]
data Ev
  = Asked Mode
    -- ^ A 'Ask' went out to the oracle. Carries the 'Harness.State.Mode' read
    -- from the node's 'Ctx' so that a 'Harness.State.Working' task ask and a
    -- 'Harness.State.Summarising' compaction ask are distinguishable in the
    -- trace — they share the 'Ask' constructor and would otherwise be
    -- indistinguishable.
  | Refused Refusal
    -- ^ The oracle answered a 'Ask' with a 'Refusal' (an 'Overflow' or a
    -- 'Malformed' decode). Emitted /in addition to/ the preceding 'Asked', right
    -- after the answer comes back and before the successor is taken; a
    -- successful 'Response' emits no event of its own.
  | Did Call
    -- ^ A 'Perform' ran a tool 'Call' against the world. Emitted before the
    -- 'Obs' comes back, so the trace records the call that was attempted even if
    -- the world action then throws in @IO@.
  | Ended Outcome
    -- ^ The walk reached a 'Halt' and stopped with this 'Outcome'. Terminal:
    -- the last event of any trace that halted rather than running out of fuel.
  deriving stock (Eq, Show)

-- | @interp askOracle askWorld fuel tree@ walks the 'Cofree' denotation from its
-- root, discharging each 'HarnessF' position by running the supplied
-- (possibly effectful) oracle\/world action and following the resulting
-- direction, until it 'Halt's or runs out of fuel. Returns @'Just' outcome@ on
-- halt, @'Nothing'@ if the fuel bound is reached first.
--
-- __Parameters.__ @askOracle@ discharges a 'Ask' (a @'Request'@ becomes an
-- @'Either' 'Refusal' 'Response'@); @askWorld@ discharges a 'Perform' (a 'Call'
-- becomes an 'Obs'). Instantiating these two — and the monad @m@ — is what turns
-- the one interpreter into @run@ (live @IO@) or @probe@ (pure). @fuel@ is the
-- depth bound; the tree can be infinite, so a bound is what guarantees the pure
-- walk terminates.
--
-- __The three cases (exhaustive, wildcard-free over 'HarnessF', invariant 1).__
-- Adding a fourth alphabet constructor must break /this/ build:
--
-- * __'Halt' o__: emit @'Ended' o@ and return @'Just' o@. Checked before the
--   fuel guard, so a halt exactly at the fuel boundary still counts as a halt.
-- * __out of fuel__ (@n <= 0@ at a non-'Halt' node): return @'Nothing'@,
--   emitting nothing. This is the only path that yields @'Nothing'@.
-- * __'Ask' q k__: emit @'Asked' (mode)@, run @askOracle q@, emit a
--   @'Refused'@ event iff the answer was a 'Refusal', then recurse on @k r@ with
--   fuel @n - 1@.
-- * __'Perform' call k__: emit @'Did' call@, run @askWorld call@, recurse on
--   @k o@ with fuel @n - 1@.
--
-- __Gotcha — fuel counts nodes, not turns.__ Every 'Ask' and 'Perform' spends
-- one unit, including the internal 'Perform's that drain a multi-call response
-- and the extra 'Ask' of a summarisation pass. It is a termination bound for
-- the pure walk, unrelated to the token @budget@ the coalgebra tracks in the
-- harness state.
--
-- __The error channel is not part of the alphabet.__ The
-- @'MonadError' 'ProviderError'@ constraint carries /transport/ failure — an
-- oracle that could not be reached after its own retries — /past/ the coalgebra
-- rather than folding it into a 'Refusal' (invariant 5). 'interp' never raises
-- one itself: the body is unchanged from the pure walk. It is the supplied
-- @askOracle@ that may 'Control.Monad.Except.throwError', and the constraint is
-- what lets that error short-circuit the walk so @Harness.Run.run@ can surface
-- it to the caller. A 'ProviderError' is /not/ a 'HarnessF' constructor and is
-- /not/ a 'Refusal'; it is deliberately outside the closed alphabet.
interp
  :: (MonadWriter [Ev] m, MonadError ProviderError m)
  => (Request -> m (Either Refusal Response))
  -> (Call -> m Obs)
  -> Int
  -> Cofree HarnessF Ctx
  -> m (Maybe Outcome)
interp askOracle askWorld = go
  where
    go _ (_ :< Halt o) = Just o <$ tell [Ended o]
    go n _ | n <= 0 = pure Nothing
    go n (c :< Ask q k) = do
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
