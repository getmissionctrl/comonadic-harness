-- | The provider seam: everything the harness needs from an LLM, and nothing
-- else. An 'Env''s @oracle@ is built from one of these. Keeping it abstract
-- lets a pure mock and the real client share a type.
module Provider.Class
  ( Provider (..)
  , providerEnv
  ) where

import Harness.Alphabet
import Harness.Run (Env (..))

-- | Abstract provider: an oracle that talks to a model plus a world that
-- executes tool calls.
data Provider m = Provider
  { complete :: Request -> m (Either Refusal Response)
  , act      :: Call -> m Obs
  }

-- | Lift a 'Provider' into a 'Harness.Run.Env', the seam the harness uses.
providerEnv :: Provider IO -> Env IO
providerEnv p = Env (complete p) (act p)
