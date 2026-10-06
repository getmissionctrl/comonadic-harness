module RefSpec (spec) where

import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (forAll, listOf, elements, (===), (.&&.))
import qualified Data.Text as T
import Harness.Alphabet (Call (..), Obs (..), RefId (..), inline)
import Harness.Preview (previewThreshold)
import Harness.Ref (emptyStore, absorb, selector)

-- Padded so it exceeds previewThreshold (256) and therefore gets parked by absorb.
bigJson :: T.Text
bigJson =
  "{\"users\":[{\"email\":\"a@x.com\"},{\"email\":\"b@x.com\"}],\"total\":2,\"pad\":\""
    <> T.replicate 300 "x" <> "\"}"

spec :: Spec
spec = describe "Harness.Ref" $ do
  it "inlines a small observation (under threshold, no ref)" $ do
    let (o, _) = absorb (inline "ok") emptyStore
    obsRef o `shouldBe` Nothing
    obsRender o `shouldBe` "ok"

  it "parks a large observation and returns a preview + ref" $ do
    let big = inline (T.replicate 400 "x")
        (o, _) = absorb big emptyStore
    obsRef o `shouldSatisfy` (/= Nothing)
    T.length (obsRender o) `shouldSatisfy` (< 400)

  it "jsonpath navigates a stored JSON value" $ do
    let (parked, st) = absorb (inline bigJson) emptyStore
    case obsRef parked of
      Just (RefId r) ->
        let (o, _) = selector (Call "jsonpath"
                       ("{\"ref\":\"" <> r <> "\",\"expr\":\"$.users[0].email\"}")) st
         in obsRender o `shouldSatisfy` T.isInfixOf "a@x.com"
      Nothing -> expectationFailure "bigJson should have been parked"

  it "jsonpath with no match renders 'no matches', not an error" $ do
    let (parked, st) = absorb (inline bigJson) emptyStore
    case obsRef parked of
      Just (RefId r) ->
        let (o, _) = selector (Call "jsonpath"
                       ("{\"ref\":\"" <> r <> "\",\"expr\":\"$.nope\"}")) st
         in obsRender o `shouldBe` "no matches"
      Nothing -> expectationFailure "bigJson should have been parked"

  it "malformed jsonpath is an error observation" $ do
    let (parked, st) = absorb (inline bigJson) emptyStore
    case obsRef parked of
      Just (RefId r) ->
        let (o, _) = selector (Call "jsonpath"
                       ("{\"ref\":\"" <> r <> "\",\"expr\":\"$.users[0\"}")) st
         in obsRender o `shouldSatisfy` T.isPrefixOf "error:"
      Nothing -> expectationFailure "bigJson should have been parked"

  it "deref returns the full stored value inline" $ do
    let (parked, st) = absorb (inline bigJson) emptyStore
    case obsRef parked of
      Just (RefId r) ->
        let (o, _) = selector (Call "deref" ("{\"ref\":\"" <> r <> "\"}")) st
         in do obsRender o `shouldBe` bigJson
               obsRef o `shouldBe` Nothing
      Nothing -> expectationFailure "bigJson should have been parked"

  it "jsonpath on an unknown ref is an error, not a crash" $ do
    let (o, _) = selector (Call "jsonpath" "{\"ref\":\"obs#999\",\"expr\":\"$\"}") emptyStore
    obsRender o `shouldSatisfy` T.isPrefixOf "error:"

  it "deref on an unknown ref is an error, not a crash" $ do
    let (o, _) = selector (Call "deref" "{\"ref\":\"obs#999\"}") emptyStore
    obsRender o `shouldSatisfy` T.isPrefixOf "error:"

  it "deref with no ref argument is an error" $ do
    let (o, _) = selector (Call "deref" "{}") emptyStore
    obsRender o `shouldBe` "error: deref requires ref"

  it "a non-selector tool is an error observation" $ do
    let (o, _) = selector (Call "read" "{}") emptyStore
    obsRender o `shouldSatisfy` T.isInfixOf "not a selector"

  prop "absorb bounds an observation's render regardless of input size" $
    -- Letters/spaces only: never valid JSON, so absorb takes the text-clip path.
    -- This quantifies the pass-by-reference payoff — the render a tool result
    -- contributes to the transcript is bounded by the preview budget, no matter
    -- how large the underlying value is — and that parking triggers exactly when
    -- the input exceeds the threshold.
    forAll (T.pack <$> listOf (elements "abcdefghij ")) $ \t ->
      let (o, _) = absorb (inline t) emptyStore
       in (T.length (obsRender o) <= previewThreshold + 3)
            .&&. ((T.length t > previewThreshold) === (obsRef o /= Nothing))
