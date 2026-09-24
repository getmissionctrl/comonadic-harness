module ToolsSpec (spec) where

import Test.Hspec
import Harness.Alphabet (Call (..), Obs (..))
import Provider.Tools (sandboxAct, prepareSandbox, trustedShellWorld, parseArgs, arg)
import System.IO.Temp (withSystemTempDirectory)
import System.Directory (createFileLink)
import System.FilePath ((</>))
import Data.List (isInfixOf)

spec :: Spec
spec = do
  describe "sandbox world seam" $ do
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

  describe "path safety (withSafePath)" $ do
    it "refuses an absolute path" $
      withSystemTempDirectory "harness-tools" $ \root -> do
        prepareSandbox root "README.md"
        Obs o <- sandboxAct root (Call "read" "{\"path\":\"/etc/passwd\"}")
        o `shouldSatisfy` \s -> take 6 s == "error:"

    it "refuses a '..' escape" $
      withSystemTempDirectory "harness-tools" $ \root -> do
        prepareSandbox root "README.md"
        Obs o <- sandboxAct root (Call "read" "{\"path\":\"../../etc/passwd\"}")
        o `shouldSatisfy` \s -> take 6 s == "error:"

    it "refuses a symlink planted inside the sandbox pointing out" $
      withSystemTempDirectory "harness-tools" $ \root -> do
        prepareSandbox root "README.md"
        -- Plant a symlink inside the sandbox that targets a path outside it.
        -- On most systems /etc/passwd exists; if not, the canonicalisation
        -- layer still detects the escape via the resolved target. [established]
        createFileLink "/etc/passwd" (root </> "escape")
        Obs o <- sandboxAct root (Call "read" "{\"path\":\"escape\"}")
        -- Either the canonicalisation layer emits "escapes sandbox" or the
        -- overall error prefix is present.
        o `shouldSatisfy` \s -> "escapes sandbox" `isInfixOf` s || take 6 s == "error:"

    it "allows a legitimate in-sandbox read" $
      withSystemTempDirectory "harness-tools" $ \root -> do
        prepareSandbox root "README.md"
        -- Write a file first, then read it back.
        Obs w <- sandboxAct root (Call "write" "{\"path\":\"note.txt\",\"body\":\"hi\"}")
        w `shouldSatisfy` \s -> take 6 s /= "error:"
        Obs o <- sandboxAct root (Call "read" "{\"path\":\"note.txt\"}")
        o `shouldSatisfy` \s -> take 6 s /= "error:"
        o `shouldSatisfy` ("hi" `isInfixOf`)

  describe "argument fallback lattice (parseArgs/arg)" $ do
    it "resolves a synonym key in a JSON object" $
      -- The model may emit \"file\" where the schema said \"path\"; both must work.
      arg ["path", "file"] (parseArgs "{\"file\":\"x.txt\"}")
        `shouldBe` Just "x.txt"

    it "treats a bare non-JSON string as Raw and resolves any key" $
      -- A model that sends a plain string instead of a JSON envelope is
      -- handled via the Raw fallback — single-argument tools still work. [design]
      arg ["path"] (parseArgs "just text")
        `shouldBe` Just "just text"

    it "unwraps a JSON-quoted string to Raw" $
      -- A JSON string value (\"quoted\") is decoded and becomes Raw of its text,
      -- not Raw of the literal string with surrounding quotes. [established]
      arg ["path"] (parseArgs "\"quoted\"")
        `shouldBe` Just "quoted"

    it "returns Nothing for a key absent from a JSON object" $
      arg ["nope"] (parseArgs "{\"path\":\"x\"}")
        `shouldBe` Nothing
