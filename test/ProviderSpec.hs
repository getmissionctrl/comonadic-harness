module ProviderSpec (spec) where

import Test.Hspec
import Control.Monad.Except (throwError)
import Data.Text qualified as T
import Harness.Alphabet
import Harness.Fault (ProviderError (..))
import Harness.Coalgebra (harness)
import Harness.Run (Env (..), run)
import Gen (startState)
import Provider.Ollama (overflowByEstimate, defaultOllamaCfg, OllamaCfg (..), renderToolObs)

-- | Invariant 5, made a checked property: a /transport/ failure raised by the
-- oracle rides the interpreter's error channel out to 'run' as a
-- @'Left' 'ProviderError'@ — it never becomes a terminal 'Outcome' the coalgebra
-- acted on. Contrast a 'Refusal', which the coalgebra /does/ fold into progress.
spec :: Spec
spec = do
  describe "provider transport failure" $
    it "surfaces as Left ProviderError, not a terminal Outcome" $ do
      let env = Env { oracle = \_ -> throwError (ProviderUnavailable "boom")
                    , world  = \c -> pure (inline (tool c <> ":ok")) }
      res <- run env (harness (startState 400))
      res `shouldBe` Left (ProviderUnavailable "boom")

  -- | Overflow is inferred from the CONFIGURED window (@ocNumCtx@), not from
  -- @promptEvalCount@. Under prefix/KV caching a long cached prompt evaluates
  -- few new tokens, which the old heuristic mistook for truncation (F3). The new
  -- estimate is independent of any token count returned by the model.
  describe "overflow estimate (uses numCtx, not evalCount)" $ do
    it "flags overflow when estimated prompt tokens exceed numCtx" $
      overflowByEstimate (defaultOllamaCfg { ocNumCtx = 64 }) (T.replicate 400 "x") `shouldBe` True
    it "does not flag a prompt that fits, regardless of eval count" $
      overflowByEstimate (defaultOllamaCfg { ocNumCtx = 2048 }) (T.replicate 400 "x") `shouldBe` False

  -- | Pass-by-reference tool-result rendering: inline observations are shown
  -- verbatim; parked observations carry the handle and an expansion instruction
  -- so the model can call deref/jsonpath itself rather than stalling.
  describe "renderToolObs" $ do
    it "returns inline obs verbatim (no deref instruction)" $ do
      let o = Obs { obsRender = "hello world", obsRef = Nothing }
      renderToolObs o `shouldBe` "hello world"
      T.isInfixOf "deref" (renderToolObs o) `shouldBe` False
    it "parked obs contains handle, deref instruction, and preview text" $ do
      let o = Obs { obsRender = "preview text", obsRef = Just (RefId "obs#0") }
      T.isInfixOf "obs#0"        (renderToolObs o) `shouldBe` True
      T.isInfixOf "deref"        (renderToolObs o) `shouldBe` True
      T.isInfixOf "preview text" (renderToolObs o) `shouldBe` True
