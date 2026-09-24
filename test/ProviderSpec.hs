module ProviderSpec (spec) where

import Test.Hspec
import Control.Monad.Except (throwError)
import Harness.Alphabet
import Harness.Fault (ProviderError (..))
import Harness.Coalgebra (harness)
import Harness.Run (Env (..), run)
import Gen (startState)
import Provider.Ollama (overflowByEstimate, defaultOllamaCfg, OllamaCfg (..))

-- | Invariant 5, made a checked property: a /transport/ failure raised by the
-- oracle rides the interpreter's error channel out to 'run' as a
-- @'Left' 'ProviderError'@ — it never becomes a terminal 'Outcome' the coalgebra
-- acted on. Contrast a 'Refusal', which the coalgebra /does/ fold into progress.
spec :: Spec
spec = do
  describe "provider transport failure" $
    it "surfaces as Left ProviderError, not a terminal Outcome" $ do
      let env = Env { oracle = \_ -> throwError (ProviderUnavailable "boom")
                    , world  = \c -> pure (Obs (tool c ++ ":ok")) }
      res <- run env (harness (startState 400))
      res `shouldBe` Left (ProviderUnavailable "boom")

  -- | Overflow is inferred from the CONFIGURED window (@ocNumCtx@), not from
  -- @promptEvalCount@. Under prefix/KV caching a long cached prompt evaluates
  -- few new tokens, which the old heuristic mistook for truncation (F3). The new
  -- estimate is independent of any token count returned by the model.
  describe "overflow estimate (uses numCtx, not evalCount)" $ do
    it "flags overflow when estimated prompt tokens exceed numCtx" $
      overflowByEstimate (defaultOllamaCfg { ocNumCtx = 64 }) (replicate 400 'x') `shouldBe` True
    it "does not flag a prompt that fits, regardless of eval count" $
      overflowByEstimate (defaultOllamaCfg { ocNumCtx = 2048 }) (replicate 400 'x') `shouldBe` False
