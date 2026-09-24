{-# LANGUAGE ScopedTypeVariables #-}

-- | Running a harness: pair the denotation tree against an effectful
-- environment.
--
-- __What.__ This module is the /execution/ half of the design. It takes a
-- 'Cofree' 'HarnessF' tree — the lazy, branching denotation obtained by
-- unfolding a coalgebra — and drives it against a real oracle (the LLM) and a
-- real world (tools), yielding a terminal 'Outcome' in 'IO'.
--
-- __Why one module, one function.__ 'run' is deliberately thin. It is
-- 'Harness.Interp.interp' specialised to the real provider and the real world,
-- in @WriterT [Ev]@ over 'IO', with the event trace __discarded__. The trace is
-- an analysis artefact; execution has no use for it. Keeping 'run' a bare
-- instance of the one shared interpreter is what buys the agreement law for
-- free: 'Harness.Probe.probe' is the /same/ 'Harness.Interp.interp' in a pure
-- monad, so /run and probe cannot drift/ — there is no second hand-written case
-- analysis to fall out of step (defect D9, §16.1). Contrast a design with two
-- loops, where the law that they agree must be re-established by inspection
-- every time either changes. [established]
--
-- __The shape, not the annotation.__ Execution consumes the /shape/ of the tree
-- (the 'HarnessF' layer: which action to take, and the successor keyed by the
-- result). It never reads the 'Harness.State.Ctx' annotation on a node
-- (invariant 2). The annotation exists for analysis ('Harness.Probe'); if a
-- field of 'Harness.State.Ctx' ever began steering execution it would belong in
-- @S@ and in @step@, not here.
--
-- __The tree is a denotation.__ Do not read the 'Cofree' argument as a
-- materialised data structure to be cached or serialised (invariant 3). It is
-- lazy and produced on demand from @S@ and the coalgebra; 'run' walks exactly
-- the single path the oracle and world select, and no more.
--
-- __Cross-references.__ The pure twin is 'Harness.Probe.probe'; the shared
-- kernel is 'Harness.Interp.interp'; the pure 'Env' used to state the agreement
-- law is 'Harness.Probe.liftHypo'.
module Harness.Run
  ( Env (..)
  , Live
  , hoistEnv
  , run
  ) where

import Control.Comonad.Cofree (Cofree)
import Control.Monad.Except (ExceptT, runExceptT)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Writer (WriterT, runWriterT)
import Harness.Alphabet
import Harness.Fault (ProviderError)
import Harness.Interp (Ev, interp)
import Harness.State (Ctx)

-- | The provider seam and the world seam — the two effectful edges of a run.
--
-- __What.__ An 'Env' is a pair of interpreters for the /directions/ of the
-- alphabet: given a 'Request' it produces a model reply (or a 'Refusal'), and
-- given a 'Call' it produces an 'Obs' from the world. The functor @m@ is the
-- effect these live in — 'IO' for a live run, or a pure 'Applicative' for the
-- forecast (see 'Harness.Probe.liftHypo').
--
-- __Why.__ Everything nondeterministic and everything effectful in a run enters
-- through exactly these two fields. That is the seam that makes the harness
-- testable: swap 'Env' and the /same/ tree runs against a stub instead of a
-- provider, which is precisely how the agreement law is stated. It is also
-- where invariant 5 is enforced — retries, backoff and transient connection
-- errors are decorators /on/ these fields and are resolved before they return,
-- so only 'Overflow' and terminal decode failures ('Malformed') ever surface as
-- a 'Refusal' to the coalgebra. [design]
--
-- __The LLM lives in exactly one field.__ 'oracle' is the /only/ place the
-- language model appears. Nothing else in the codebase talks to a provider;
-- 'run' does not, the coalgebra does not, analysis does not. That single
-- containment is what lets 'Harness.Probe' reason about a machine's future
-- without ever calling out — it substitutes a pure 'oracle' and folds.
data Env m = Env
  { oracle :: Request -> m (Either Refusal Response)
    -- ^ The provider seam: the sole point of contact with the language model.
    -- A 'Left' is a 'Refusal' the coalgebra is permitted to see — 'Overflow'
    -- (context exceeded) or 'Malformed' (a terminal decode failure). Transient
    -- faults must never be returned /as/ a 'Refusal' (invariant 5); a fault that
    -- survives the provider's own retries is raised instead on @m@'s error
    -- channel as a @Harness.Fault.ProviderError@ (see 'Live'\/'run'), so it
    -- rides past the coalgebra rather than being mistaken for a terminal refusal.
  , world  :: Call -> m Obs
    -- ^ The world seam: run a tool 'Call' and observe its result. Total in @m@;
    -- a failed tool is an 'Obs' describing the failure, not an exception that
    -- escapes the seam.
  }

-- | Drive the harness tree to termination against a real 'Env', in 'IO'.
--
-- __What.__ Walk the 'Cofree' 'HarnessF' tree one node at a time, at each node
-- performing the 'oracle' or 'world' action named by the shape and following
-- the successor keyed by the result, until the tree reaches a 'Halt' and yields
-- its 'Outcome'.
--
-- __How.__ 'run' is 'Harness.Interp.interp' with the two seams lifted from
-- 'Env' into @WriterT [Ev] IO@, then 'Control.Monad.Writer.runWriterT' applied
-- and the accumulated @[Ev]@ trace dropped on the floor (bound to @_evs@).
-- Execution wants the 'Outcome', not the trace; the trace is what
-- 'Harness.Probe.probe' keeps. Because both go through the one 'interp', they
-- agree on the path taken by construction (§16.1).
--
-- __Why fuel is 'maxBound'.__ 'Harness.Interp.interp' is depth-bounded so that
-- /analysis/ can look a finite distance ahead; a live run has no such horizon —
-- it should stop when the machine says to, i.e. on 'Halt', not because a
-- counter ran out. Passing 'maxBound' makes the fuel guard practically
-- unreachable. The @Nothing@ branch (fuel exhausted before 'Halt') is therefore
-- a can't-happen; it is mapped to @'Stuck' \"fuel exhausted\"@ defensively
-- rather than left partial. [design]
--
-- __The 'Left' result.__ A @'Left' e@ is /not/ an 'Outcome': it means the
-- provider was unavailable — a transport fault that outlived the provider's own
-- retries — so no terminal verdict could be reached (invariant 5). The state is
-- resumable: a caller may run the same tree again later when the provider
-- recovers. A run that reaches a 'Halt' yields @'Right' o@; the error never
-- becomes a 'Refusal' the coalgebra can act on. [design]
run :: Env Live -> Cofree HarnessF Ctx -> IO (Either ProviderError Outcome)
run env w = do
  (res, _evs :: [Ev]) <-
    runWriterT (runExceptT (interp (\_ -> pure ()) (oracle env) (world env) maxBound w))
  pure (fmap (maybe (Stuck "fuel exhausted") id) res)

-- | The concrete monad a live 'run' walks in: transport failure on an
-- 'ExceptT' channel over the interpreter's @'WriterT' ['Ev']@ trace over 'IO'.
--
-- __Why a named alias.__ The two seams of a live 'Env' now live in this stack
-- rather than plain 'IO', so callers construct their oracle\/world directly in
-- 'Live' (via 'liftIO' or 'Control.Monad.Except.throwError') instead of 'run'
-- lifting them in. Naming the stack keeps those call sites — and 'hoistEnv' —
-- readable. The 'WriterT' trace is an analysis artefact 'run' discards; the
-- 'ExceptT' channel carries the @'ProviderError'@ that invariant 5 forbids from
-- becoming a 'Refusal'. [design]
type Live = ExceptT ProviderError (WriterT [Ev] IO)

-- | Lift an @'Env' 'IO'@ into an @'Env' m@ for any @'MonadIO' m@ (in practice
-- 'Live'), by running each seam through 'liftIO'.
--
-- __Why.__ Several environments are naturally written in plain 'IO' — a
-- scripted fake, the human-in-the-loop seam, a streaming builder that owns its
-- own emission — and never raise a @'ProviderError'@. 'hoistEnv' embeds such an
-- 'Env' into the richer 'Live' stack that 'run' now requires, without forcing
-- each to be rewritten monad-polymorphically. A seam that /does/ fault (the
-- Ollama oracle) is built directly in the target monad instead. [design]
hoistEnv :: MonadIO m => Env IO -> Env m
hoistEnv env = Env
  { oracle = \q -> liftIO (oracle env q)
  , world  = \c -> liftIO (world env c)
  }
