module ToolsSpec (spec) where

import Test.Hspec
import qualified Data.Text as T
import Data.IORef (newIORef)
import qualified Data.Map.Strict as Map
import Harness.Alphabet (Call (..), Obs (..), obsRender, obsRef, RefId (..), inline)
import Harness.Preview (previewThreshold)
import Harness.Ref (emptyStore)
import Provider.Tools (sandboxAct, prepareSandbox, trustedShellWorld, refWorld, onceReadWorld, parseArgs, arg)
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

    it "parks a scrape_url result eagerly, yet leaves a same-size read inline" $ do
      -- A ~8 KB payload sits between scrapeThreshold (2000) and previewThreshold
      -- (16000): the per-tool policy parks it for scrape_url (web pages
      -- accumulate) but leaves it inline for read (local files the model needs).
      store <- newIORef emptyStore
      let payload = T.replicate 8000 "x"
          base _  = pure (inline payload)
          w       = refWorld store base
      scraped <- w (Call "scrape_url" "{\"url\":\"https://example\"}")
      obsRef scraped `shouldSatisfy` (/= Nothing)
      red <- w (Call "read" "{\"path\":\"f.txt\"}")
      obsRef red `shouldBe` Nothing

  describe "idempotent-read guard (onceReadWorld)" $ do
    it "collapses an unchanged re-read to a note, not the full content" $
      withSystemTempDirectory "harness-once" $ \root -> do
        prepareSandbox root "README.md"
        writeFile (root </> "f.txt") "the quick brown fox"
        store <- newIORef emptyStore
        seen  <- newIORef Map.empty
        let w = onceReadWorld seen (refWorld store (sandboxAct root))
        o1 <- w (Call "read" "{\"path\":\"f.txt\"}")
        obsRender o1 `shouldBe` "the quick brown fox"   -- first read: full content
        o2 <- w (Call "read" "{\"path\":\"f.txt\"}")
        obsRender o2 `shouldSatisfy` T.isInfixOf "already read"
        obsRender o2 `shouldSatisfy` \s -> not (T.isInfixOf "quick" s)  -- content NOT re-appended

    it "re-reads in full when the file content has changed" $
      withSystemTempDirectory "harness-once" $ \root -> do
        prepareSandbox root "README.md"
        store <- newIORef emptyStore
        seen  <- newIORef Map.empty
        let w = onceReadWorld seen (refWorld store (sandboxAct root))
        _  <- w (Call "write" "{\"path\":\"f.txt\",\"body\":\"one\"}")
        o1 <- w (Call "read" "{\"path\":\"f.txt\"}")
        obsRender o1 `shouldBe` "one"
        _  <- w (Call "write" "{\"path\":\"f.txt\",\"body\":\"two is different\"}")
        o2 <- w (Call "read" "{\"path\":\"f.txt\"}")
        obsRender o2 `shouldBe` "two is different"       -- changed ⇒ not collapsed

    it "resolves a synonym path key so {path} and {file} share one entry" $
      withSystemTempDirectory "harness-once" $ \root -> do
        prepareSandbox root "README.md"
        writeFile (root </> "f.txt") "contents here"
        store <- newIORef emptyStore
        seen  <- newIORef Map.empty
        let w = onceReadWorld seen (refWorld store (sandboxAct root))
        _  <- w (Call "read" "{\"path\":\"f.txt\"}")
        o2 <- w (Call "read" "{\"file\":\"f.txt\"}")
        obsRender o2 `shouldSatisfy` T.isInfixOf "already read"

    it "passes non-read calls through unchanged" $
      withSystemTempDirectory "harness-once" $ \root -> do
        prepareSandbox root "README.md"
        store <- newIORef emptyStore
        seen  <- newIORef Map.empty
        let w = onceReadWorld seen (refWorld store (sandboxAct root))
        o <- w (Call "write" "{\"path\":\"g.txt\",\"body\":\"x\"}")
        obsRender o `shouldSatisfy` T.isInfixOf "wrote"

    it "does not collapse a parked (large) read — its preview cannot overflow" $
      withSystemTempDirectory "harness-once" $ \root -> do
        prepareSandbox root "README.md"
        writeFile (root </> "big.txt") (replicate (previewThreshold + 100) 'x')
        store <- newIORef emptyStore
        seen  <- newIORef Map.empty
        let w = onceReadWorld seen (refWorld store (sandboxAct root))
        o1 <- w (Call "read" "{\"path\":\"big.txt\"}")
        obsRef o1 `shouldSatisfy` (/= Nothing)   -- parked
        o2 <- w (Call "read" "{\"path\":\"big.txt\"}")
        obsRef o2 `shouldSatisfy` (/= Nothing)   -- still parked, not a note
        obsRender o2 `shouldSatisfy` \s -> not (T.isInfixOf "already read" s)
