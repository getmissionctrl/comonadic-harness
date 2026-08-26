module Main (main) where

import Test.Hspec (hspec)
import qualified LawsSpec
import qualified PerfSpec
import qualified HostileSpec

main :: IO ()
main = hspec $ do
  LawsSpec.spec
  PerfSpec.spec
  HostileSpec.spec
