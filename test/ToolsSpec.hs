module ToolsSpec (spec) where

import Test.Hspec
import Harness.Alphabet (Call (..), Obs (..))
import Provider.Tools (sandboxAct, prepareSandbox)
import System.IO.Temp (withSystemTempDirectory)

spec :: Spec
spec = describe "sandbox world seam" $ do
  it "refuses bash by default (shell is opt-in)" $
    withSystemTempDirectory "harness-tools" $ \root -> do
      prepareSandbox root "README.md"
      Obs o <- sandboxAct root (Call "bash" "{\"cmd\":\"echo hi\"}")
      o `shouldSatisfy` \s -> take 6 s == "error:"
