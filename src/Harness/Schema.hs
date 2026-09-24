-- | The terse tool-argument schema DSL shared by the affordance/admission layer
-- and the Ollama provider. A spec like @"{path:string,body:string}"@ parses to
-- its declared fields. Kept as ONE definition so the coalgebra's argument
-- validation ('Harness.State.admit') and the provider's typed tool advertisement
-- ('Provider.Ollama') cannot drift. [design]
module Harness.Schema
  ( schemaFields
  , requiredKeys
  ) where

-- | Parse @"{k1:t1,k2:t2}"@ into @[(k1,t1),(k2,t2)]@ (names and json-ish types).
-- Ported verbatim from the old @Provider.Ollama.parseSpec@ so there is one
-- definition of the DSL: the affordance layer validates against it and the
-- provider builds its typed tool advertisement from it, and the two cannot drift.
-- Whitespace around keys and types is trimmed; an empty key drops the field.
schemaFields :: String -> [(String, String)]
schemaFields raw =
  [ (trim k, trim (drop 1 v))
  | field <- splitComma inner
  , let (k, v) = break (== ':') field
  , not (null (trim k))
  ]
  where
    inner = takeWhile (/= '}') (drop 1 (dropWhile (/= '{') raw))
    trim  = f . f where f = reverse . dropWhile (== ' ')
    splitComma [] = []
    splitComma s  = let (a, b) = break (== ',') s
                    in a : case b of [] -> []; (_ : rest) -> splitComma rest

-- | Just the declared field names of a schema. Used by 'Harness.State.admit' to
-- decide, per tool, how strict argument validation must be.
requiredKeys :: String -> [String]
requiredKeys = map fst . schemaFields
