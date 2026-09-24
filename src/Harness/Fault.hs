-- | Provider transport failure — deliberately OUTSIDE the closed 'Refusal'
-- alphabet (invariant 5). A 'ProviderError' means the oracle could not be
-- reached or answered after the provider's own retries were exhausted; it is
-- not a 'Refusal' the coalgebra can act on, so it rides the interpreter's error
-- channel and is surfaced by @Harness.Run.run@ to the caller, who may resume the
-- same state later. The pure analyser (@probe@) never raises one.
module Harness.Fault (ProviderError (..)) where

import GHC.Generics (Generic)

data ProviderError = ProviderUnavailable String
  deriving stock (Eq, Show, Generic)
