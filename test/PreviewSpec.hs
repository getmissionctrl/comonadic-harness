module PreviewSpec (spec) where

import Test.Hspec
import Data.Aeson (Value, object, (.=))
import qualified Data.Text as T
import qualified Data.Vector as V
import Harness.Preview (preview, previewResult)

big :: Value
big = object [ "users" .= V.generate 1000 (\i -> object ["id" .= i])
             , "total" .= (1000 :: Int) ]

spec :: Spec
spec = describe "Harness.Preview" $ do
  it "summarises a huge object to a small, structural preview" $ do
    let p = preview big
    T.length p `shouldSatisfy` (< 120)
    p `shouldSatisfy` T.isInfixOf "users"
    p `shouldSatisfy` T.isInfixOf "1000 items"

  it "renders integers without a trailing .0" $
    preview (object ["n" .= (1000 :: Int)]) `shouldSatisfy` T.isInfixOf "1000"

  it "renders integers without a trailing .0, negatively" $
    preview (object ["n" .= (1000 :: Int)]) `shouldNotSatisfy` T.isInfixOf "1000.0"

  it "previewResult of one match is that match's preview" $
    previewResult (V.singleton (object ["id" .= (1 :: Int)])) `shouldSatisfy` T.isInfixOf "id"

  it "previewResult of many matches is a bounded count summary" $
    previewResult (V.generate 1000 (\i -> object ["id" .= i]))
      `shouldSatisfy` T.isInfixOf "1000 matches"
