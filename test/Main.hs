module Main (main) where

import Test.Hspec (hspec)
import qualified LawsSpec

main :: IO ()
main = hspec LawsSpec.spec
