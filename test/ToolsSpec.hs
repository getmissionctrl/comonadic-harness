module ToolsSpec (spec) where

import Test.Hspec
import qualified Data.Text as T
import Data.IORef (newIORef)
import Harness.Alphabet (Call (..), Obs (..), obsRender, obsRef, RefId (..))
import Harness.Preview (previewThreshold)
import Harness.Ref (emptyStore)
import Provider.Tools (sandboxAct, prepareSandbox, trustedShellWorld, refWorld, parseArgs, arg)
import System.IO.Temp (withSystemTempDirectory)
import System.Directory (createFileLink)
import System.FilePath ((</>))

spec :: Spec
spec = do
  describe "sandbox world seam" $ do
    it "refuses bash by default (shell is opt-in)" $
      withSystemTempDirectory "harness-tools" $ \root -> do
        prepareSandbox root "README.md"
        o <- obsRender <$> sandboxAct root (Call "bash" "{\"cmd\":\"echo hi\"}")
        o `shouldSatisfy` \s -> T.take 6 s == "error:"

    it "trustedShellWorld runs a command and returns its output" $
      withSystemTempDirectory "harness-tools" $ \root -> do
        prepareSandbox root "README.md"
        o <- obsRender <$> trustedShellWorld root (Call "bash" "{\"cmd\":\"echo hi\"}")
        o `shouldSatisfy` \s -> "hi" `elem` T.words s
        o `shouldSatisfy` \s -> T.take 5 s == "bash "

    it "trustedShellWorld forwards non-bash calls to sandboxAct" $
      withSystemTempDirectory "harness-tools" $ \root -> do
        prepareSandbox root "README.md"
        o <- obsRender <$> trustedShellWorld root (Call "read" "{\"path\":\"README.md\"}")
        o `shouldSatisfy` \s -> T.take 6 s /= "error:"

  describe "path safety (withSafePath)" $ do
    it "refuses an absolute path" $
      withSystemTempDirectory "harness-tools" $ \root -> do
        prepareSandbox root "README.md"
        o <- obsRender <$> sandboxAct root (Call "read" "{\"path\":\"/etc/passwd\"}")
        o `shouldSatisfy` \s -> T.take 6 s == "error:"

    it "refuses a '..' escape" $
      withSystemTempDirectory "harness-tools" $ \root -> do
        prepareSandbox root "README.md"
        o <- obsRender <$> sandboxAct root (Call "read" "{\"path\":\"../../etc/passwd\"}")
        o `shouldSatisfy` \s -> T.take 6 s == "error:"

    it "refuses a symlink planted inside the sandbox pointing out" $
      withSystemTempDirectory "harness-tools" $ \root -> do
        prepareSandbox root "README.md"
        -- Plant a symlink inside the sandbox that targets a path outside it.
        -- On most systems /etc/passwd exists; if not, the canonicalisation
        -- layer still detects the escape via the resolved target. [established]
        createFileLink "/etc/passwd" (root </> "escape")
        o <- obsRender <$> sandboxAct root (Call "read" "{\"path\":\"escape\"}")
        -- Either the canonicalisation layer emits "escapes sandbox" or the
        -- overall error prefix is present.
        o `shouldSatisfy` \s -> "escapes sandbox" `T.isInfixOf` s || T.take 6 s == "error:"

    it "allows a legitimate in-sandbox read" $
      withSystemTempDirectory "harness-tools" $ \root -> do
        prepareSandbox root "README.md"
        -- Write a file first, then read it back.
        w <- obsRender <$> sandboxAct root (Call "write" "{\"path\":\"note.txt\",\"body\":\"hi\"}")
        w `shouldSatisfy` \s -> T.take 6 s /= "error:"
        o <- obsRender <$> sandboxAct root (Call "read" "{\"path\":\"note.txt\"}")
        o `shouldSatisfy` \s -> T.take 6 s /= "error:"
        o `shouldSatisfy` T.isInfixOf "hi"

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

  describe "pass-by-reference world" $ do
    it "parks a large JSON read and lets jsonpath navigate it" $
      withSystemTempDirectory "harness-ref" $ \root -> do
        prepareSandbox root "README.md"
        let body = "{\"users\":[{\"email\":\"a@x.com\"}],\"pad\":\""
                     ++ replicate (previewThreshold + 100) 'x' ++ "\"}"
        writeFile (root </> "data.json") body
        store <- newIORef emptyStore
        let w = refWorld store (sandboxAct root)
        o1 <- w (Call "read" "{\"path\":\"data.json\"}")
        obsRef o1 `shouldSatisfy` (/= Nothing)     -- large read is parked
        case obsRef o1 of
          Just (RefId r) -> do
            o2 <- w (Call "jsonpath"
                       ("{\"ref\":\"" <> r <> "\",\"expr\":\"$.users[0].email\"}"))
            obsRender o2 `shouldSatisfy` T.isInfixOf "a@x.com"
          Nothing -> expectationFailure "large read should have been parked"

    it "leaves a small read inline (no ref)" $
      withSystemTempDirectory "harness-ref" $ \root -> do
        prepareSandbox root "README.md"
        writeFile (root </> "tiny.txt") "hello"
        store <- newIORef emptyStore
        let w = refWorld store (sandboxAct root)
        o <- w (Call "read" "{\"path\":\"tiny.txt\"}")
        obsRef o `shouldBe` Nothing
        obsRender o `shouldBe` "hello"
