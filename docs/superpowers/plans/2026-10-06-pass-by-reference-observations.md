# Pass-by-reference observations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Large tool results are parked in a world-side store; only a bounded structural preview + a ref id enter the transcript, and the model navigates with a `jsonpath` selector — keeping the context prefix-stable for constrained/local models.

**Architecture:** Two stages in one plan. **Stage A** is a mechanical `String → Text` migration of the core (no behaviour change, compiler- and suite-guided). **Stage B** adds pass-by-reference on top: `Obs` becomes a `{render, ref}` product, a pure ref `Store` + `preview`/`jsonpath` layer, and a world decorator that thresholds results — all without touching the closed `HarnessF` alphabet (the selectors are ordinary `Call`s through the existing `Perform`).

**Tech Stack:** Haskell (GHC2021), `aeson`, `aeson-jsonpath` (RFC 9535 JSONPath, used via its TH-free sub-modules), `text`, `containers`, `hspec`, `QuickCheck`.

**Reference:** spec at `docs/superpowers/specs/2026-10-06-pass-by-reference-observations-design.md`.

**Working rules:** `-Wall -Wcompat -Wincomplete-uni-patterns -Wincomplete-patterns -Wredundant-constraints -Wmissing-export-lists` must stay clean (no wildcard added to `run`/`probe`/laws). Build/test in the dev shell: `nix develop -c cabal build` / `nix develop -c cabal test`. British spelling in prose/comments; Haddock on every new export saying *why*.

---

## Stage A — `String → Text` migration (no behaviour change)

`text` is already a dependency and `OverloadedStrings` is on, so this adds nothing to the build. It is a compiler-guided sweep: flip the type declarations, then fix every error GHC reports, module by module, until the suite is green. **No behaviour changes** — the three laws (agreement, prefix-stability, compaction bisimulation) must prove exactly as before.

**Mechanical rules for every body you touch:**
- `(++)` on these payloads → `(<>)`; `concat`/`concatMap` → `<>`/`foldMap`.
- `unlines` → `Data.Text.unlines`; `lines` → `Data.Text.lines`; `take`/`drop`/`length`/`null`/`isPrefixOf`/`isInfixOf`/`takeWhile`/`elem`-on-chars → the `Data.Text` equivalents (import `qualified Data.Text as T`).
- String literals need no change (OverloadedStrings).
- At IO/JSON boundaries that are genuinely `String` (file contents via `readFile`, `show`, `aeson`'s `decode`/`encode` on `ByteString`, `System.*`): convert with `T.pack`/`T.unpack` / `TE.encodeUtf8` / `TE.decodeUtf8` right at the boundary, keeping `Text` in the core.

### Task A1: Flip the alphabet types to `Text`

**Files:**
- Modify: `src/Harness/Alphabet.hs`

- [ ] **Step 1: Change the payload-carrying declarations**

```haskell
-- add near the imports:
import qualified Data.Text as T   -- if any body needs T.* here
import Data.Text (Text)

newtype Prompt = Prompt Text
  deriving stock (Eq, Show, Generic)

data ToolSpec = ToolSpec { specName :: Text, specSchema :: Text }
  deriving stock (Eq, Show, Generic)

data Call = Call { tool :: Text, args :: Text }
  deriving stock (Eq, Show, Generic)

newtype Obs = Obs Text               -- becomes a product in Task B3
  deriving stock (Eq, Show, Generic)

data ChatMsg
  = MsgUser Text
  | MsgAssistant Text [Call]
  | MsgToolResult Call Obs
  deriving stock (Eq, Show, Generic)

data Response = Response { say :: Text, calls :: [Call], usage :: Usage }
  deriving stock (Eq, Show, Generic)

data Refusal  = Overflow | Malformed Text
  deriving stock (Eq, Show, Generic)

data Outcome  = Done Text | Exhausted | Failed Text | Stuck Text
  deriving stock (Eq, Show, Generic)
```

`Usage`, `HarnessF`, `ReplaySafety` are unchanged.

- [ ] **Step 2: Build just this module's reverse-dep closure later.** Do not build yet — the consumers break. Proceed to A2–A5, then build once at A6.

### Task A2: Fix `State.hs` (the quotients)

**Files:**
- Modify: `src/Harness/State.hs`

- [ ] **Step 1: Flip `Turn` and the renderers/projection**

```haskell
import qualified Data.Text as T

data Turn = Assistant Response | User [(Call, Obs)] | Summary Text
  deriving stock (Eq, Show, Generic)

renderLine :: Turn -> Text
renderLine (Assistant r) = "A: " <> say r <> foldMap (\c -> " <" <> tool c <> ">") (calls r)
renderLine (User rs)     = "U: " <> foldMap (\(c, Obs o) -> tool c <> "=" <> o <> " ") rs
renderLine (Summary t)   = "S: " <> t

project :: S -> Prompt
project s = Prompt (T.unlines (map renderLine (reverse (transcript s))))
```

- [ ] **Step 2: Fix `allTools`, `afford`, `admit`, `argsSatisfy`, `settle`, `request`, `toChatMsgs`, `view`** for `Text`. Concretely: the `"error: …"` constructions become `Obs ("error: " <> …)` with `<>`; `specName`/`tool`/`specSchema` comparisons stay (literals are `Text`); `argsSatisfy`'s `decode (BSLC.pack (args c))` becomes `decode (BL.fromStrict (TE.encodeUtf8 (args c)))` (add `qualified Data.Text.Encoding as TE`, `qualified Data.ByteString.Lazy as BL`); `request`'s summarise append uses `<>`; `isPrefixOf` on the error convention (in `afford`'s `wrote`) becomes `T.isPrefixOf`.

### Task A3: Fix the coalgebra and analysis modules

**Files:**
- Modify: `src/Harness/Coalgebra.hs`, `src/Harness/Compaction.hs`, `src/Harness/Probe.hs`, `src/Harness/Fault.hs`, `src/Harness/Schema.hs`, `src/Harness/Interp.hs`

- [ ] **Step 1:** Apply the mechanical rules. Hot spots: `Coalgebra.admit`'s error `Obs` and `record`; `Compaction.observe`/`bWrites` string handling and any `isPrefixOf`/`unpack`; `Probe`'s `Ev` rendering; `Schema.requiredKeys`/`keySynonyms` (these return `[Text]` now — check call sites in `State.argsSatisfy` and `Provider.Tools`); `Fault` diagnostics. No logic changes.

### Task A4: Fix the providers and AG-UI transport

**Files:**
- Modify: `src/Provider/Tools.hs`, `src/Provider/Ollama.hs`, `src/Provider/Research.hs`, `src/Harness/AgUi/Translate.hs`, `src/Harness/AgUi/Sink.hs`, `src/Harness/AgUi/Server.hs`

- [ ] **Step 1:** `Provider/Tools.hs` keeps its internals `String` (file IO, `System.Process`, `System.FilePath` are `String`) and converts at the `Obs` boundary only: `sandboxAct`/`trustedShellWorld` build `Obs (T.pack (...))`; `keySynonyms`/`arg` interop with `Text` keys via `T.unpack` where they index aeson. `Ollama.hs` renders `MsgToolResult`/`MsgAssistant` from `Text` (its HTTP/JSON client converts at the wire via `TE.encodeUtf8`). AG-UI modules convert at the SSE/JSON boundary.

### Task A5: Fix the tests

**Files:**
- Modify: `test/Gen.hs`, `test/LawsSpec.hs`, `test/PerfSpec.hs`, `test/HostileSpec.hs`, `test/ProviderSpec.hs`, `test/ToolsSpec.hs`, `test/AgUi*Spec.hs`

- [ ] **Step 1:** Update generators and assertions to `Text`. In `ToolsSpec` the `Obs o <- …; o `shouldSatisfy` \s -> take 6 s == "error:"` idioms become `T.take 6 o == "error:"` (import `qualified Data.Text as T`). `Gen.hs` generates `Text` turns (`T.pack <$> …` or `elements` of `Text` literals). The prefix-stability law in `LawsSpec.hs:126-130` becomes `whole === rest <> renderLine t <> "\n"`.

### Task A6: Build, test, commit the migration

- [ ] **Step 1: Build**

Run: `nix develop -c cabal build all`
Expected: compiles clean, **zero warnings** (the `common warnings` set).

- [ ] **Step 2: Test**

Run: `nix develop -c cabal test`
Expected: all specs PASS — identical results to before (agreement, prefix-stability, compaction-defect, closed-alphabet, affordance, hostile, provider, AG-UI).

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "refactor: migrate core String payloads to Text (no behaviour change)"
```

---

## Stage B — pass-by-reference observations

### Task B1: Add the `aeson-jsonpath` dependency

**Files:**
- Modify: `comonadic-harness.cabal`, `default.nix` (Haskell package-set override)

- [ ] **Step 1: Add to the library build-depends** (`comonadic-harness.cabal`, after the `aeson` line):

```
    , aeson-jsonpath       >= 0.3  && < 0.5
```

- [ ] **Step 2: Make nix provide it.** `aeson-jsonpath` may be absent from the pinned nixpkgs `haskellPackages`. In `default.nix`, where the package set / `callCabal2nix` is assembled, add it via `callHackageDirect` (fill the sha from the first failing build's message):

```nix
# in the haskellPackages override:
aeson-jsonpath =
  self.callHackageDirect {
    pkg = "aeson-jsonpath";
    ver = "0.4.2.0";
    sha256 = "";   # paste the sha nix prints on first run, then rebuild
  } {};
```

If version-bound friction appears, `pkgs.haskell.lib.doJailbreak` it. **Fallback** (if a build-graph TH dep is unacceptable per the invariant): vendor `Data.Aeson.JSONPath.{Parser,Query,Types,Types.*,Query.*}` under `src/Vendor/` and drop this dependency — do NOT vendor the top `Data.Aeson.JSONPath` module (it is the only TH importer).

- [ ] **Step 2b: Verify it resolves** with a throwaway import in `ghci`:

Run: `nix develop -c cabal repl comonadic-harness` then `:m + Data.Aeson.JSONPath.Query`
Expected: loads with no error.

- [ ] **Step 3: Commit**

```bash
git add comonadic-harness.cabal default.nix
git commit -m "build: depend on aeson-jsonpath (RFC 9535 JSONPath, TH-free sub-modules)"
```

### Task B2: The pure `Harness.Preview` module

**Files:**
- Create: `src/Harness/Preview.hs`
- Modify: `comonadic-harness.cabal` (expose it), `test/Main.hs` + cabal `other-modules` (register `PreviewSpec`)
- Test: `test/PreviewSpec.hs`

- [ ] **Step 1: Write the failing test** (`test/PreviewSpec.hs`)

```haskell
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
    T.length p `shouldSatisfy` (< 120)          -- bounded regardless of 1000 users
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `nix develop -c cabal test --test-option=--match --test-option="Harness.Preview"`
Expected: FAIL — `preview`/`previewResult` not in scope.

- [ ] **Step 3: Implement `Harness.Preview`** (`src/Harness/Preview.hs`)

```haskell
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
import Data.List (intercalate)
import Data.Scientific (Scientific, floatingOrInteger)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V

-- | Results larger than this many characters are parked in the store and
-- previewed; smaller ones stay inline. The one knob that wants empirical tuning
-- for a given local model / context window. [design]
previewThreshold :: Int
previewThreshold = 256

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

-- intercalate from Data.List is unused once T.intercalate is in; drop the import
-- if -Wunused-imports fires.
```

- [ ] **Step 4: Register and run**

Add `Harness.Preview` to the cabal library `exposed-modules`; add `PreviewSpec` to the test `other-modules` and to `test/Main.hs` (`describe "preview" PreviewSpec.spec` alongside the others).
Run: `nix develop -c cabal test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/Harness/Preview.hs test/PreviewSpec.hs test/Main.hs comonadic-harness.cabal
git commit -m "feat(preview): type-directed structural JSON previews"
```

### Task B3: `Obs` becomes a `{render, ref}` product

**Files:**
- Modify: `src/Harness/Alphabet.hs`, then the compiler-indicated sites (`State.hs`, `Coalgebra.hs`, `Provider/Tools.hs`, `Provider/Ollama.hs`, `test/ToolsSpec.hs`, AG-UI)

This task has **no behaviour change**: everything becomes `inline`, so `obsRef` is always `Nothing` and the suite stays green. It only widens the type.

- [ ] **Step 1: Widen `Obs` and add `RefId`** (`src/Harness/Alphabet.hs`)

```haskell
import Data.Text (Text)

-- | A handle to a full observation value parked in the world store. The model
-- never sees the full value inline for a large result; it sees this id in the
-- transcript and dereferences it with a selector 'Call' ('jsonpath'\/'deref').
newtype RefId = RefId Text
  deriving stock (Eq, Ord, Show, Generic)

-- | The world's reply to a 'Perform'. 'obsRender' is what enters the transcript
-- (inline text, or a bounded structural preview); 'obsRef' is 'Just' the store
-- handle when the full value was too large to inline. Still the direction of a
-- 'Perform' position — no new alphabet constructor. [design]
data Obs = Obs
  { obsRender :: Text
  , obsRef    :: Maybe RefId
  }
  deriving stock (Eq, Show, Generic)

-- | Smart constructor for an observation whose full value is small enough to
-- live inline in the transcript (no store entry).
inline :: Text -> Obs
inline t = Obs t Nothing
```

Export `RefId (..)`, `Obs (..)`, and `inline` in the module's export list.

- [ ] **Step 2: Fix construction sites** — every `Obs x` that builds an observation becomes `inline x`:
  - `State.admit`: `inline ("error: tool not afforded: " <> tool c)` and `inline ("error: invalid arguments for " <> tool c <> …)`.
  - `Provider/Tools.sandboxAct` / `trustedShellWorld`: `pure (inline (T.pack (...)))`.

- [ ] **Step 3: Fix destructuring sites** — every `Obs o` pattern that reads the text uses `obsRender`:
  - `State.renderLine (User rs)`:

```haskell
renderLine (User rs) = "U: " <> foldMap renderOne rs
  where
    renderOne (c, o) = tool c <> "=" <> body o <> " "
    body o = case obsRef o of
      Nothing       -> obsRender o
      Just (RefId r) -> r <> " <" <> obsRender o <> ">"
```

  - `State.toChatMsgs` / `Provider.Ollama` `MsgToolResult c o` rendering: use `obsRender o`.
  - `test/ToolsSpec.hs`: `Obs o <- sandboxAct …` becomes `o <- obsRender <$> sandboxAct …`.

- [ ] **Step 4: Build + test (behaviour unchanged)**

Run: `nix develop -c cabal build all && nix develop -c cabal test`
Expected: PASS, warnings clean. `obsRef` is `Nothing` everywhere so every law proves as before.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor(alphabet): Obs becomes a {render, ref} product (inline everywhere; no behaviour change)"
```

### Task B4: The pure `Harness.Ref` store + selector layer

**Files:**
- Create: `src/Harness/Ref.hs`
- Modify: `comonadic-harness.cabal` (expose), `test/Main.hs` + cabal `other-modules` (register `RefSpec`)
- Test: `test/RefSpec.hs`

- [ ] **Step 1: Write the failing test** (`test/RefSpec.hs`)

```haskell
module RefSpec (spec) where

import Test.Hspec
import qualified Data.Text as T
import Harness.Alphabet (Call (..), Obs (..), RefId (..), inline)
import Harness.Ref (emptyStore, absorb, selector)

bigJson :: T.Text
bigJson = "{\"users\":[{\"email\":\"a@x.com\"},{\"email\":\"b@x.com\"}],\"total\":2}"

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
        Just (RefId r) = obsRef parked
        (o, _) = selector (Call "jsonpath"
                   ("{\"ref\":\"" <> r <> "\",\"expr\":\"$.users[0].email\"}")) st
    obsRender o `shouldSatisfy` T.isInfixOf "a@x.com"

  it "jsonpath with no match renders 'no matches', not an error" $ do
    let (parked, st) = absorb (inline bigJson) emptyStore
        Just (RefId r) = obsRef parked
        (o, _) = selector (Call "jsonpath"
                   ("{\"ref\":\"" <> r <> "\",\"expr\":\"$.nope\"}")) st
    obsRender o `shouldBe` "no matches"

  it "malformed jsonpath is an error observation" $ do
    let (parked, st) = absorb (inline bigJson) emptyStore
        Just (RefId r) = obsRef parked
        (o, _) = selector (Call "jsonpath"
                   ("{\"ref\":\"" <> r <> "\",\"expr\":\"$.users[0\"}")) st
    obsRender o `shouldSatisfy` T.isPrefixOf "error:"

  it "deref returns the full stored value inline" $ do
    let (parked, st) = absorb (inline bigJson) emptyStore
        Just (RefId r) = obsRef parked
        (o, _) = selector (Call "deref" ("{\"ref\":\"" <> r <> "\"}")) st
    obsRender o `shouldBe` bigJson
    obsRef o `shouldBe` Nothing

  it "jsonpath on an unknown ref is an error, not a crash" $ do
    let (o, _) = selector (Call "jsonpath" "{\"ref\":\"obs#999\",\"expr\":\"$\"}") emptyStore
    obsRender o `shouldSatisfy` T.isPrefixOf "error:"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `nix develop -c cabal test --test-option=--match --test-option="Harness.Ref"`
Expected: FAIL — `Harness.Ref` not found.

- [ ] **Step 3: Implement `Harness.Ref`** (`src/Harness/Ref.hs`)

```haskell
-- | The world-side reference store and the pure selector layer. Large tool
-- results are parked here under a 'RefId'; only a 'preview' enters the
-- transcript. The model dereferences with ordinary selector 'Call's
-- ('jsonpath'\/'deref') performed through the existing 'Perform' — the alphabet
-- is untouched. Pure: an 'IORef' wrapper ('Harness.Ref.world') owns the state
-- at the IO boundary, but the decisions live here and are unit-tested here.
-- [design]
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
import qualified Data.Vector as V

import qualified Text.ParserCombinators.Parsec as P
import Data.Aeson.JSONPath.Parser (pQuery)
import Data.Aeson.JSONPath.Query (qQuery)
import Data.Aeson.JSONPath.Types (QueryState (..))

import Harness.Alphabet (Call (..), Obs (..), RefId (..), inline)
import Harness.Preview (preview, previewResult, previewThreshold, clipText)

-- | A monotonic, per-run store of full observation values keyed by handle.
data Store = Store { refs :: Map RefId Text, nextId :: Int }

emptyStore :: Store
emptyStore = Store Map.empty 0

put :: Text -> Store -> (RefId, Store)
put t (Store m n) = let r = RefId ("obs#" <> T.pack (show n))
                     in (r, Store (Map.insert r t m) (n + 1))

-- | Threshold a freshly-produced observation. Over 'previewThreshold' chars:
-- park the full value and return a structural preview (JSON if it parses,
-- otherwise a clipped-text preview) plus the ref. Otherwise pass it through
-- inline untouched.
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

-- | Resolve a selector 'Call' against the store. Handles @jsonpath@ and
-- @deref@; anything else is an error observation (it should never be afforded).
-- Never throws — a bad ref, non-JSON ref, or malformed expression all become
-- error observations the model can read and recover from.
selector :: Call -> Store -> (Obs, Store)
selector c st = case tool c of
  "deref"    -> (withRef (\full -> (inline full, st)), st') `orErr`
                 lookupArg "ref" c
  "jsonpath" -> runJsonpath
  other      -> (inline ("error: not a selector: " <> other), st)
  where
    -- deref
    withRef k = k ""  -- placeholder, replaced below
    orErr = const
    st' = st

    runJsonpath = case (lookupArg "ref" c, lookupArg "expr" c) of
      (Just r, Just expr) -> case Map.lookup (RefId r) (refs st) of
        Nothing   -> (inline ("error: no such ref: " <> r), st)
        Just full -> case decodeStrict (TE.encodeUtf8 full) :: Maybe Value of
          Nothing  -> (inline ("error: ref " <> r <> " is not JSON"), st)
          Just v   -> case P.parse pQuery "jsonpath" (T.unpack expr) of
            Left perr -> (inline ("error: " <> T.pack (unwords (lines (show perr)))), st)
            Right q   ->
              let vs = qQuery q QueryState { rootVal = v, curVal = v, executeQuery = qQuery }
               in absorb (Obs (previewResult vs) Nothing) st   -- re-threshold big results
      _ -> (inline "error: jsonpath requires ref and expr", st)

-- | Minimal single-key lookup in a call's JSON args (the selectors use flat
-- @{\"ref\":…,\"expr\":…}@ objects).
lookupArg :: Text -> Call -> Maybe Text
lookupArg k c = case decodeStrict (TE.encodeUtf8 (args c)) :: Maybe Value of
  Just (Object o) -> case KM.lookup (K.fromText k) o of
    Just (String t) -> Just t
    _               -> Nothing
  _ -> Nothing
```

> **Implementer note:** the `deref` branch above is sketched with placeholders (`withRef`/`orErr`) to keep the shape visible — replace it with the direct form:
> ```haskell
>   "deref" -> case lookupArg "ref" c of
>     Just r  -> case Map.lookup (RefId r) (refs st) of
>       Just full -> (inline full, st)
>       Nothing   -> (inline ("error: no such ref: " <> r), st)
>     Nothing -> (inline "error: deref requires ref", st)
> ```
> and delete the `withRef`/`orErr`/`st'` helpers. (This note exists because the happy-path code must be exact; do not ship the placeholder form.)

- [ ] **Step 4: Register and run**

Add `Harness.Ref` to cabal `exposed-modules`; register `RefSpec` in cabal `other-modules` and `test/Main.hs`.
Run: `nix develop -c cabal test --test-option=--match --test-option="Harness.Ref"`
Expected: all 7 examples PASS.

- [ ] **Step 5: Commit**

```bash
git add src/Harness/Ref.hs test/RefSpec.hs test/Main.hs comonadic-harness.cabal
git commit -m "feat(ref): pure store + jsonpath/deref selector layer"
```

### Task B5: Wire the ref layer into the live world + afford the selectors

**Files:**
- Modify: `src/Provider/Tools.hs` (world decorator; stop clipping so full content reaches the threshold layer), `src/Harness/State.hs` (`allTools`, `afford`), `src/Harness/Run.hs` (build the decorated world with a fresh store per run)
- Test: `test/ToolsSpec.hs`

- [ ] **Step 1: Write the failing test** (`test/ToolsSpec.hs`, new `describe`)

```haskell
  describe "pass-by-reference world" $ do
    it "parks a large read and lets jsonpath navigate it" $
      withSystemTempDirectory "harness-ref" $ \root -> do
        prepareSandbox root "README.md"
        store <- newIORef emptyStore
        let w = refWorld store (sandboxAct root)
        -- seed a large JSON file
        _ <- w (Call "write"
                 ("{\"path\":\"data.json\",\"body\":"
                   <> tshowJSON (T.replicate 50 "{\"email\":\"a@x.com\"},")
                   <> "}"))   -- see note: simplest is to write a known big JSON blob
        o1 <- w (Call "read" "{\"path\":\"data.json\"}")
        obsRef o1 `shouldSatisfy` (/= Nothing)                 -- big read is ref'd
        let Just (RefId r) = obsRef o1
        o2 <- w (Call "jsonpath" ("{\"ref\":\"" <> r <> "\",\"expr\":\"$[0].email\"}"))
        obsRender o2 `shouldSatisfy` T.isInfixOf "a@x.com"
```

> **Implementer note:** craft `data.json` as a valid large JSON array of `{"email":…}` objects (≥ `previewThreshold` bytes). Keep the write body a literal valid-JSON array; `tshowJSON` is illustrative — inline the literal string instead.

Add imports to `ToolsSpec`: `Data.IORef (newIORef)`, `Harness.Alphabet (RefId (..), obsRef, obsRender)`, `Harness.Ref (emptyStore)`, `Provider.Tools (refWorld)`, `qualified Data.Text as T`.

- [ ] **Step 2: Run it to verify it fails**

Run: `nix develop -c cabal test --test-option=--match --test-option="pass-by-reference world"`
Expected: FAIL — `refWorld` not in scope.

- [ ] **Step 3: Implement the world decorator** (`src/Provider/Tools.hs`)

```haskell
import Data.IORef (IORef, atomicModifyIORef')
import Harness.Ref (Store, absorb, selector)

-- | Decorate a base world with the reference store: selector calls
-- (@jsonpath@\/@deref@) are resolved from the store; every other result is
-- thresholded — parked + previewed when large, passed through inline when
-- small. The store is per-run mutable state owned here at the IO boundary; the
-- decisions are the pure 'Harness.Ref' functions. [design]
refWorld :: IORef Store -> (Call -> IO Obs) -> Call -> IO Obs
refWorld ref base c
  | tool c `elem` ["jsonpath", "deref"] =
      atomicModifyIORef' ref (\st -> swap (selector c st))
  | otherwise = do
      o <- base c
      atomicModifyIORef' ref (\st -> swap (absorb o st))
  where
    swap (a, b) = (b, a)
```

Add `refWorld` to the module export list. Remove the `clip 800` in `readTool` and the `clip 800` in `trustedShell` so the full content reaches `absorb` (the ref layer now does the bounding; small outputs are still inline). Leave `firstLine`'s clip on `commit` output (tiny, not ref-worthy).

- [ ] **Step 4: Afford the selectors** (`src/Harness/State.hs`)

```haskell
allTools :: [ToolSpec]
allTools =
  [ ToolSpec "read" "{path:string}"
  , ToolSpec "write" "{path:string,body:string}"
  , ToolSpec "commit" "{msg:string}"
  , ToolSpec "jsonpath" "{ref:string,expr:string}"
  , ToolSpec "deref" "{ref:string}"
  ]
```

In `afford`, the selectors must be offered in `Working` mode (read-only, safe) and must NOT be gated behind the `commit` precondition. Simplest: they are part of `tools s`, and the existing `commit`-withholding filter only removes `commit`, so `jsonpath`/`deref` already survive. Confirm the `Summarising` branch still returns `[]`.

- [ ] **Step 5: Build the decorated world per run** (`src/Harness/Run.hs`)

Where the live `Env` is constructed with `world = sandboxAct root` (or `trustedShellWorld root`), allocate a fresh store and wrap it:

```haskell
-- at run construction (IO), once per run:
store <- newIORef emptyStore
let liveWorld = refWorld store (sandboxAct root)
-- use liveWorld as Env.world
```

The pure `guessWorld` used by `probe` is unchanged (no store; returns `inline` guesses) — `probe` never dereferences real content.

- [ ] **Step 6: Run the full suite**

Run: `nix develop -c cabal build all && nix develop -c cabal test`
Expected: PASS, warnings clean. The new world test passes; all prior specs still green (selectors are additive; `afford` in `Summarising` still `[]`).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(world): reference-store world decorator; afford jsonpath/deref"
```

### Task B6: Strengthen the prefix-stability law to a Σ-preview bound

**Files:**
- Modify: `test/LawsSpec.hs`, `test/Gen.hs`

- [ ] **Step 1: Write the property** (`test/LawsSpec.hs`, in the prefix-stability `describe`)

```haskell
    prop "transcript render is bounded by the sum of per-turn preview sizes" $
      \ts ->
        let Prompt whole = project (startStateWith ts)
            bound = sum [ T.length (renderLine t) + 1 | t <- ts ]   -- +1 per newline
         in T.length whole <= bound
```

This states the pass-by-reference payoff as a law: the rendered prompt never exceeds the sum of the (bounded) per-turn previews — it cannot be inflated by full observation bodies. `Gen.hs` already generates reachable turns through public transitions (§16.7); ensure its `Obs` generator can produce both `inline` and ref'd observations so the bound is exercised on both.

- [ ] **Step 2: Add a closed-alphabet assertion comment** in the closed-alphabet test noting the selectors are `Call`s performed through `Perform`, not new `HarnessF` constructors — so no case was added to `run`/`probe`/laws.

- [ ] **Step 3: Run**

Run: `nix develop -c cabal test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add test/LawsSpec.hs test/Gen.hs
git commit -m "test(laws): prefix-stability strengthened to a sum-of-previews bound"
```

### Task B7: Record the E1 reframe

**Files:**
- Modify: `TASKS.md` (and optionally a one-line note in `BRIEF.md` §14 E1)

- [ ] **Step 1:** Add a `[design]`-tagged note that pass-by-reference obviates compaction in the common case, reframing E1 from "compaction-defect rate" to a compacting-vs-reference coalgebra bake-off (per-component `Behaviour` divergence + prefix-stability + evaluated-token cost). Keep `Summarising` as the retained rare fallback. Mark the bake-off `[unbuilt]`.

- [ ] **Step 2: Commit**

```bash
git add TASKS.md BRIEF.md
git commit -m "docs: record E1 reframe (compacting vs reference coalgebra)"
```

---

## Self-review notes (resolved)

- **Spec coverage:** threshold (B5 `absorb`), JSON-only `jsonpath` + wholesale `deref` (B4/B5), keep-compaction (untouched; B7 note), store-behind-world (B4 pure / B5 IORef), `Text`-everywhere (Stage A), closed alphabet (B3/B6), TH-free dependency (B1), preview-not-truncation (B2), Σ-preview law (B6) — all mapped.
- **Type consistency:** `Obs { obsRender :: Text, obsRef :: Maybe RefId }`, `RefId Text`, `inline :: Text -> Obs`, `absorb :: Obs -> Store -> (Obs, Store)`, `selector :: Call -> Store -> (Obs, Store)`, `refWorld :: IORef Store -> (Call -> IO Obs) -> Call -> IO Obs`, `preview :: Value -> Text`, `previewResult :: Vector Value -> Text`, `previewThreshold :: Int` — used consistently across tasks.
- **Placeholder honesty:** the `Harness.Ref.selector` `deref` branch is shown twice — a shape-only sketch and the exact replacement in the implementer note; ship the exact form. The `ToolsSpec` big-JSON body and `Gen.hs` `Obs` generator are flagged as requiring a concrete literal/arbitrary rather than the illustrative helper.
```
