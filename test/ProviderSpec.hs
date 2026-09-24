module ProviderSpec (spec) where

import Test.Hspec
import Control.Monad.Except (throwError)
import Harness.Alphabet
import Harness.Fault (ProviderError (..))
import Harness.Coalgebra (harness)
import Harness.Run (Env (..), run)
import Gen (startState)

-- | Invariant 5, made a checked property: a /transport/ failure raised by the
-- oracle rides the interpreter's error channel out to 'run' as a
-- @'Left' 'ProviderError'@ — it never becomes a terminal 'Outcome' the coalgebra
-- acted on. Contrast a 'Refusal', which the coalgebra /does/ fold into progress.
spec :: Spec
spec = describe "provider transport failure" $
  it "surfaces as Left ProviderError, not a terminal Outcome" $ do
    let env = Env { oracle = \_ -> throwError (ProviderUnavailable "boom")
                  , world  = \c -> pure (Obs (tool c ++ ":ok")) }
    res <- run env (harness (startState 400))
    res `shouldBe` Left (ProviderUnavailable "boom")
