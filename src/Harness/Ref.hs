-- | The world-side reference store and the pure selector layer. Large tool
-- results are parked here under a 'RefId'; only a 'preview' enters the
-- transcript. The model dereferences with ordinary selector 'Call's
-- ('jsonpath'\/'deref') performed through the existing 'Perform' — the alphabet
-- is untouched. Pure here; an 'IORef' wrapper owns the state at the IO boundary
-- in a later task. [design]
module Harness.Ref
  ( Store
  , emptyStore
  , absorb
  , selector
  ) where

import Data.Aeson (Value (..), decodeStrict)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

import qualified Text.ParserCombinators.Parsec as P
import Data.Aeson.JSONPath.Parser (pQuery)
import Data.Aeson.JSONPath.Query (qQuery)
import Data.Aeson.JSONPath.Types (QueryState (..))

import Harness.Alphabet (Call (..), Obs (..), RefId (..), inline)
import Harness.Preview (preview, previewResult, previewThreshold, clipText)

-- | A monotonic, per-run store of full observation values keyed by handle.
data Store = Store { refs :: Map RefId Text, nextId :: Int }

-- | The store a run starts with: no parked values yet. Each run gets a fresh
-- one so refs never collide across runs. (Ids begin at @obs#0@.)
emptyStore :: Store
emptyStore = Store Map.empty 0

put :: Text -> Store -> (RefId, Store)
put t st =
  let n = nextId st
      r = RefId ("obs#" <> T.pack (show n))
   in (r, Store (Map.insert r t (refs st)) (n + 1))

-- | Keep a large tool result out of the transcript without losing it: park the
-- full value under a ref and surface only a bounded preview (JSON-structural if
-- it parses, otherwise a clipped-text preview), so the model's context stays
-- small while the data remains retrievable. Small results (at or under
-- 'previewThreshold' chars) pass through inline, untouched.
absorb :: Obs -> Store -> (Obs, Store)
absorb o st
  | T.length (obsRender o) <= previewThreshold = (o, st)
  | otherwise =
      let full = obsRender o
          (r, st') = put full st
          prev = case decodeStrict (TE.encodeUtf8 full) :: Maybe Value of
                   Just v  -> preview v
                   Nothing -> clipText previewThreshold full
       in (Obs prev (Just r), st')

-- | Let the model pull just the part of a parked value it needs, instead of
-- re-reading the whole thing into context. Resolves @jsonpath@ (navigate with a
-- JSONPath expression) and @deref@ (retrieve the full parked value) against the
-- store. Never throws — a bad ref, non-JSON ref, or malformed expression all
-- become error observations the model can read and recover from.
selector :: Call -> Store -> (Obs, Store)
selector c st = case tool c of
  "deref" -> case lookupArg "ref" c of
    Just r  -> case Map.lookup (RefId r) (refs st) of
      Just full -> (inline full, st)
      Nothing   -> (inline ("error: no such ref: " <> r), st)
    Nothing -> (inline "error: deref requires ref", st)
  "jsonpath" -> case (lookupArg "ref" c, lookupArg "expr" c) of
    (Just r, Just expr) -> case Map.lookup (RefId r) (refs st) of
      Nothing   -> (inline ("error: no such ref: " <> r), st)
      Just full -> case decodeStrict (TE.encodeUtf8 full) :: Maybe Value of
        Nothing -> (inline ("error: ref " <> r <> " is not JSON"), st)
        Just v  -> case P.parse pQuery "jsonpath" (T.unpack expr) of
          Left perr -> (inline ("error: " <> T.replace "\n" " " (T.pack (show perr))), st)
          Right q   ->
            let vs = qQuery q QueryState { rootVal = v, curVal = v, executeQuery = qQuery }
             in absorb (Obs (previewResult vs) Nothing) st
    _ -> (inline "error: jsonpath requires ref and expr", st)
  other -> (inline ("error: not a selector: " <> other), st)  -- [design] selector set and afforded set stay in sync

-- | Minimal single-key lookup in a call's JSON args (the selectors use flat
-- @{\"ref\":…,\"expr\":…}@ objects).
lookupArg :: Text -> Call -> Maybe Text
lookupArg k c = case decodeStrict (TE.encodeUtf8 (args c)) :: Maybe Value of
  Just (Object o) -> case KM.lookup (K.fromText k) o of
    Just (String t) -> Just t
    _               -> Nothing
  _ -> Nothing
