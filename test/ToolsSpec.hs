module ToolsSpec (spec) where

import Test.Hspec
import Harness.Alphabet (Call (..), Obs (..))
import Provider.Tools (sandboxAct, prepareSandbox, trustedShellWorld)
import System.IO.Temp (withSystemTempDirectory)

spec :: Spec
spec = describe "sandbox world seam" $ do
  it "refuses bash by default (shell is opt-in)" $
    withSystemTempDirectory "harness-tools" $ \root -> do
      prepareSandbox root "README.md"
      Obs o <- sandboxAct root (Call "bash" "{\"cmd\":\"echo hi\"}")
      o `shouldSatisfy` \s -> take 6 s == "error:"

  it "trustedShellWorld runs a command and returns its output" $
    withSystemTempDirectory "harness-tools" $ \root -> do
      prepareSandbox root "README.md"
      Obs o <- trustedShellWorld root (Call "bash" "{\"cmd\":\"echo hi\"}")
      o `shouldSatisfy` \s -> "hi" `elem` words s
      o `shouldSatisfy` \s -> take 5 s == "bash "

  it "trustedShellWorld forwards non-bash calls to sandboxAct" $
    withSystemTempDirectory "harness-tools" $ \root -> do
      prepareSandbox root "README.md"
      Obs o <- trustedShellWorld root (Call "read" "{\"path\":\"README.md\"}")
      o `shouldSatisfy` \s -> take 6 s /= "error:"
