-- | The provider seam: everything the harness needs from the outside, and
-- nothing else.
--
-- __What.__ A 'Provider' bundles the two — and only two — capabilities the
-- coalgebra cannot supply for itself: an /oracle/ that answers a 'Request' (the
-- model) and a /world/ that executes a 'Call' (the tools). The @oracle@ of a
-- @Harness.Run.Env@ is built from one of these via 'providerEnv'.
--
-- __Why abstract.__ The whole design hinges on the LLM living behind a single
-- seam and nowhere else. Keeping 'Provider' a plain record — rather than, say, a
-- typeclass — lets a pure mock and the real HTTP client share one type, so the
-- analyser can drive the very same shape the live driver walks. Swapping a
-- scripted provider for 'Provider.Ollama.ollamaProvider' is then a local value
-- substitution, not a change to the coalgebra.
--
-- __The slogan.__ @complete@ = the oracle, @act@ = the world. Analysis mocks
-- both; a live run wires both to reality. [design]
module Provider.Class
  ( Provider (..)
  , providerEnv
  ) where

import Harness.Alphabet
import Harness.Run (Env (..))

-- | The two capabilities the harness needs from the outside world, parameterised
-- over the effect @m@ (so a pure @'Data.Functor.Identity.Identity'@ mock and an
-- @IO@ client share the type).
data Provider m = Provider
  { complete :: Request -> m (Either Refusal Response)
    -- ^ The oracle. Given the projected 'Request' (prompt plus afforded tools),
    -- answer with a 'Response' or a terminal 'Refusal'. Only 'Overflow' and a
    -- terminal decode failure ('Harness.Alphabet.Malformed') count as refusals;
    -- transient trouble (timeouts, 5xx, socket errors) must be absorbed /inside/
    -- this function and never surfaced as a 'Refusal' (invariant 5).
  , act      :: Call -> m Obs
    -- ^ The world. Execute one tool 'Call' and return the 'Obs' the model sees
    -- next turn. A scripted world stubs this; the live world is the sandboxed
    -- executor 'Provider.Tools.sandboxAct'. It must not throw — an execution
    -- failure is reported /as/ an 'Obs', preserving the harness's
    -- crash-freedom property.
  }

-- | Lift a 'Provider' into a @Harness.Run.Env@, the record the driver actually
-- pairs against the unfolded tree.
--
-- __Why it exists.__ 'Provider' is the /author-facing/ shape (two named
-- capabilities); @Env@ is the /driver-facing/ shape. They are structurally the
-- same, but keeping them distinct lets 'Provider' grow provider-specific
-- conveniences without the coalgebra ever seeing more than the two fields it
-- consumes. Monad-polymorphic (like 'Env'): it merely repackages the two fields,
-- so it imposes no @IO@ specialisation of its own — a live 'Provider' in
-- @Harness.Run.Live@ becomes a @Harness.Run.Env Live@, a pure mock stays pure.
-- [design]
providerEnv :: Provider m -> Env m
providerEnv p = Env (complete p) (act p)
