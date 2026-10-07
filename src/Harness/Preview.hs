-- | Type-directed structural summaries of JSON values and query results.
-- A /preview/ is a depth-1 shape summary — keys, array lengths, scalars — NOT a
-- byte-truncation: its size is bounded by object breadth, independent of array
-- length or nesting depth. It is what lets a large observation enter the
-- transcript as a few bytes while the full value stays in the world store.
-- [design]
module Harness.Preview
  ( preview
  , previewResult
  , previewThreshold
  , clipText
  ) where

import Data.Aeson (Value (..))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Scientific (Scientific, floatingOrInteger)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V

-- | Results larger than this many characters are parked in the store and
-- previewed; smaller ones stay inline. Sized so that only results that would
-- consume a large fraction of a typical context window get parked — roughly
-- half of an 8k-token window (~16k chars). A smaller value (e.g. 256) parks
-- ordinary files that fit the window perfectly well, which needlessly pushes
-- the model into a @deref@ round-trip (and, observed with small models, a
-- re-fetch loop) instead of just using the content. Ideally this tracks the
-- run's @num_ctx@; for now it is a fixed, deliberately generous constant.
-- [design]
previewThreshold :: Int
previewThreshold = 16000

-- | A depth-1 structural summary of a JSON value.
preview :: Value -> Text
preview (Object o) =
  "object {" <> T.intercalate ", "
    [ K.toText k <> ": " <> brief val | (k, val) <- KM.toList o ] <> "}"
preview (Array a)  = "array[" <> tshow (V.length a) <> " items]"
preview v          = brief v

-- | One level shallower: used for the fields shown inside a 'preview'.
brief :: Value -> Text
brief (Object o) = "{" <> tshow (length (KM.keys o)) <> " keys}"
brief (Array a)  = "[" <> tshow (V.length a) <> " items]"
brief (String t) = tshow (clipText 24 t)
brief (Number n) = num n
brief (Bool b)   = if b then "true" else "false"
brief Null       = "null"

-- | A preview of a JSONPath query /result/ (a vector of matched nodes).
previewResult :: V.Vector Value -> Text
previewResult vs
  | V.null vs        = "no matches"
  | V.length vs == 1 = preview (V.head vs)
  | otherwise        =
      tshow (V.length vs) <> " matches: ["
        <> T.intercalate ", " (map brief (take 5 (V.toList vs)))
        <> (if V.length vs > 5 then ", ..." else "") <> "]"

-- | Render a 'Scientific' as an integer when it is one (no trailing @.0@),
-- otherwise as a decimal.
num :: Scientific -> Text
num n = case floatingOrInteger n :: Either Double Integer of
  Right i -> tshow i
  Left d  -> tshow d

-- | Clip a 'Text' to @n@ characters with an elision marker — the degenerate
-- preview for unstructured text.
clipText :: Int -> Text -> Text
clipText n t
  | T.length t <= n = t
  | otherwise       = T.take n t <> "..."

tshow :: Show a => a -> Text
tshow = T.pack . show
