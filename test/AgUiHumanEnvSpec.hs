module AgUiHumanEnvSpec (spec) where

import Test.Hspec
import Control.Concurrent (forkIO)
import Control.Concurrent.STM
import Harness.Alphabet
import Harness.Run (Env (..))
import Harness.AgUi.HumanEnv

spec :: Spec
spec = describe "Harness.AgUi.HumanEnv" $
  it "blocks the oracle until input is provided, then returns it" $ do
    slot <- newInputSlot
    emitted <- newTVarIO (0 :: Int)
    let autoWorld = \_ -> pure (Obs "auto")
        env = humanEnv (\_ -> atomically (modifyTVar' emitted (+1))) slot autoWorld
    -- fork the blocking oracle call
    result <- newEmptyTMVarIO
    _ <- forkIO $ do
      r <- oracle env (Request (Prompt "please decide") [] [])
      atomically (putTMVar result r)
    -- provide input
    atomically (provideInput slot (Right (Response "human says go" [] (Usage 0 0))))
    r <- atomically (takeTMVar result)
    case r of
      Right rsp -> say rsp `shouldBe` "human says go"
      Left _    -> expectationFailure "expected a Response"
    e <- readTVarIO emitted
    e `shouldBe` 1   -- the awaiting-input signal fired once
