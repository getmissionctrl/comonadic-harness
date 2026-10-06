# Pass-by-reference observations (on a `Text` baseline)

*Design spec. Status: draft for review. Date: 2026-10-06.*

## Provenance key

`[established]` proved/demonstrated here · `[design]` a defensible choice ·
`[speculative]` untested · `[unbuilt]` named, not implemented.

## 1. Motivation

Two industry write-ups (NVIDIA's NOOA "six agent harness capabilities", and
FineEnvs' multi-harness RL guide) independently report that harness design —
not the model — produces double-digit performance and cost swings, and that the
single biggest lever is **how tool results enter the context**. NOOA's
headline mechanism is *pass by reference*: the full result stays live in the
execution environment, the model sees a bounded preview, and the transcript
stays "append-only and cache-valid throughout" (median sessions peak at 22–72k
prompt tokens against 200–400k windows). `[established, external]`

In this project's vocabulary "append-only and cache-valid" is exactly the
**prefix-stability law (§16.6)**:

```
project (t : ts) == project ts <> renderLine t <> "\n"
```

Today that law holds only *within* a `Working` streak. It is broken at every
compaction: `Summarising` collapses the whole transcript to one `Summary`
turn, rewriting the rendered prefix and invalidating the KV cache (the brief
already budgets this cache-miss into E1's cost model). The thing that *forces*
compaction is that `renderLine (User …)` dumps the **full** observation text
into the prompt (`State.hs:150`), so the transcript grows proportionally to
observation size, depletes `budget`, fills the window, and trips `Overflow`.

Pass-by-reference attacks the cause: bound each observation line at the source,
so the transcript grows slowly, `Overflow` rarely fires, compaction rarely
runs, and prefix-stability holds for (almost) the whole session. This matters
most for **local models and constrained context windows**, which is the target
workload. `[design]`

A scratch demo (`aeson-jsonpath`, GHC 9.10.3) confirmed the round-trip: a
67,774-byte JSON blob rendered as a 94-byte structural preview (721× smaller),
with `$.users[0].email`, slices, wildcards, and filters all resolving against
the stored value, and malformed queries returning a parse error suitable for an
error observation. `[established]`

## 2. Goals / non-goals

**Goals.**
- A **reference observation**: large tool results are parked in a world-side
  store; only a structural preview + a ref id enter the transcript.
- A **`jsonpath` selector** and a **`deref`** tool so the model can navigate or
  retrieve stored values, each navigation appending a bounded, prefix-stable
  turn.
- `Text` throughout the core (replacing `String`), done **first**, as the
  baseline the feature is written against.
- No new `HarnessF` constructor; the closed-alphabet, `run`-never-reads-
  annotation, and `run`/`probe`-agreement invariants preserved.

**Non-goals (YAGNI, deferred).**
- Text selectors (`slice`, `grep`) — only `jsonpath` + `deref` in v1. Large
  non-JSON results are previewed and readable only whole (via `deref`).
- Removing compaction — `Summarising` stays as a rarely-fired fallback.
- Afford-by-masking for tool-schema prefix-stability — noted as a separate,
  quieter obligation; out of scope here.
- Durable/resumable store (D4) — the store is per-run, in-memory.

## 3. Scope decisions (settled)

| Question | Decision |
|---|---|
| Which observations get preview+ref | **Threshold**: only results over `previewThreshold` bytes; small results stay inline as today. |
| Selector surface | **JSON only**: `jsonpath` + a wholesale `deref`. |
| Compaction | **Keep** `Summarising` as a rare fallback; unchanged. |
| Store location | **Behind `Env.world`** (design A); never in `S`, never in `Ctx`. |
| `String` vs `Text` | **`Text` everywhere**, migrated first. |

## 4. Implementation order: two stages in one spec

### Stage A — `String → Text` migration (mechanical, no behaviour change)

`text >= 2.0` is already a dependency and `OverloadedStrings`/
`OverloadedRecordDot` are already on, so this adds no dependency. 54 `String`
occurrences across 11 modules. The interlocking core types flip:

```haskell
newtype Prompt = Prompt Text
newtype Obs    = Obs Text            -- (becomes a product in Stage B)
data Outcome   = Done Text | Exhausted | Failed Text | Stuck Text
data Refusal   = Overflow | Malformed Text
data Turn      = … | Summary Text
renderLine :: Turn -> Text
project    :: S -> Prompt
```

Mechanical consequences: `(++)` → `(<>)`, `unlines` → `Data.Text.unlines`,
`concatMap`/`isPrefixOf` → their `Data.Text` equivalents, `putStr`/show sites in
the providers and `AgUi` converting at the HTTP/JSON boundary only. The error
convention `"error: " \`isPrefixOf\`` becomes `Text.isPrefixOf`.

**Exit criterion:** the whole suite (law tests, `PerfSpec`, `HostileSpec`,
`ToolsSpec`, provider specs) is green and `-Wall -Wcompat
-Wincomplete-uni-patterns -Wredundant-constraints` is clean, with **no
behaviour change**. The three laws (agreement, prefix-stability, compaction
bisimulation) must prove exactly as before. This stage is a pure refactor and
is reviewable on its own diff. `[design]`

### Stage B — pass-by-reference observations

Built on the `Text` baseline.

#### 4.1 The core move: richer payloads, closed alphabet

`jsonpath` and `deref` are ordinary `Call`s performed through the **existing**
`Perform`. The store and preview logic live in the `world`. `HarnessF` is
untouched — no new case in `run`, `probe`, or the closed-alphabet law. This is
the brief's "nondeterminism in the directions, not the positions". `[design]`

#### 4.2 Types

```haskell
newtype RefId = RefId Text            -- e.g. "obs#7"

data Obs = Obs
  { obsRender :: Text                 -- what lands in the transcript
  , obsRef    :: Maybe RefId          -- Just r when the full value is stored
  }

inline :: Text -> Obs                 -- smart ctor: obsRef = Nothing
inline t = Obs t Nothing
```

Every existing `Obs x` site becomes `inline x`. The threshold decision is
expressed in the type: small → `inline`, large → `Obs preview (Just ref)`.

#### 4.3 The store (world-side)

The live `world` closes over per-run mutable state:

```haskell
-- in the Live world construction (Provider/Tools.hs)
store   :: IORef (Map RefId Text)     -- ref → full result text (undecoded)
nextRef :: IORef Int                  -- monotonic id source
```

The store never appears in the `Env` type; it is captured in the `world`
closure. The pure `guessWorld` used by `probe` has **no** store and returns
`inline` guesses — consistent with "probe never dereferences real content".
Values are stored as raw `Text`; `jsonpath` decodes on demand, so non-JSON
results can still be stored and `deref`'d. `[design]`

#### 4.4 Data flow (the `Perform` loop)

```
read {path} → world runs it → result 67 KB
  size > previewThreshold ⇒ ref := allocate; store[ref] := full
                            return Obs (preview v) (Just ref)
  transcript:  U: read=obs#7 ⟨object {users:[1000], meta:{2 keys}, total:1000}⟩

jsonpath {ref="obs#7", expr="$.users[0].email"}
  world: store[obs#7] → decode JSON → runQuery expr
    Right vs, small       ⇒ Obs (previewResult vs) Nothing
    Right vs, over thresh ⇒ Obs (previewResult vs) (Just ref')    -- recurses
    Left parseErr         ⇒ Obs ("error: " <> …) Nothing
    decode failure        ⇒ Obs ("error: obs#7 is not JSON") Nothing
  transcript:  U: jsonpath="user0@example.com"

deref {ref="obs#7"} → store[obs#7] → Obs fullText Nothing   -- model's explicit flood
```

`Right []` (valid query, no match) renders as `"no matches"`, **not** an error.

#### 4.5 Preview (new pure module `Harness.Preview`)

```haskell
preview       :: Value -> Text        -- depth-1 structural summary
previewResult :: Vector Value -> Text  -- 1 match → preview it; N → "N matches: […]"
previewThreshold :: Int               -- bytes; [design], tunable — the local-model knob
```

Lifted from the verified scratch, with a tidy scalar renderer (integers without
`.0`, long strings elided). `preview`'s size is bounded by object *breadth*, not
array length or nesting depth.

#### 4.6 Tools & affordance

`allTools` (`State.hs`) gains:

```haskell
ToolSpec "jsonpath" "{ref:string,expr:string}"
ToolSpec "deref"    "{ref:string}"
```

`afford` offers both in `Working` mode (read-only, safe; `[]` in `Summarising`
as today). They do not interact with the `commit`-gate. Their always-present-
in-`Working` status keeps the afforded set stable turn-to-turn.

#### 4.7 Dependency

Depend on `aeson-jsonpath`, importing only `Data.Aeson.JSONPath.{Parser,Query,
Types}` and re-stating its three-line `query` as a local `runQuery` (demonstrated
in scratch). The top module — the only one importing Template Haskell, for an
optional QuasiQuoter — is never imported, so **no TH enters this project's
code**; `template-haskell` remains a contained build-graph dependency of the
package. `query :: String -> Value -> Either ParseError (Vector Value)` takes a
`String`, so the selector's `Text` expr is `unpack`ed only at that boundary.
Nix: add the package to the flake's Haskell set (small overlay if absent from
the pinned set). Vendoring the ~9 TH-free modules is the fallback if a build-
graph TH dep is unacceptable; not recommended (maintenance cost). `[design]`

## 5. Modules touched (Stage B, over the Text baseline)

| File | Change |
|---|---|
| `Harness/Alphabet.hs` | `Obs` → product; `inline`; `RefId` |
| `Harness/State.hs` | `renderLine` uses `obsRender` (+ shows ref id); `allTools` += `jsonpath`,`deref`; `afford` offers them in `Working` |
| `Provider/Tools.hs` | store (`IORef`), ref allocation, threshold, `jsonpath`/`deref` handlers in the live `world` |
| `Harness/Preview.hs` | **new**, pure |
| `Harness/Coalgebra.hs` | `admit` repaired-call error `Obs` → `inline` (no logic change) |
| `AgUi/Translate.hs`, tests | mechanical `Obs` constructor updates |
| `*.cabal`, `flake.nix` | `aeson-jsonpath` |

## 6. Invariants & laws

**Invariants preserved.**
1. Closed alphabet — no new constructor; a test comment asserts the selectors
   are `Call`s, not constructors.
2. `run` never reads the annotation — preview/ref logic is in the `world`,
   not `step` or `Ctx`.
3. `Cofree` unchanged.
4. Evolution untouched.
5. Store is world-side; transient faults still ride `ProviderError`.

**Laws.**
- *Agreement* (§16.1): unchanged — both paths still factor through `interp`.
- *Prefix-stability* (§16.6): still holds in `Working`; **strengthened** claim
  worth a property — transcript size is bounded by Σ *preview* sizes, not Σ
  *full* sizes.
- *Compaction bisimulation* (§16.2): unchanged; `Summarising` untouched.

**New properties (tests).**
- Threshold: `size ≤ previewThreshold ⇒ obsRef == Nothing`; `> ⇒ Just`.
- Round-trip: `jsonpath`/`deref` against a seeded store resolve from the stored
  value (pure world + store fixture).
- Error path: malformed expr or non-JSON ref ⇒ `obsRender` begins `"error: "`.
- No-match: `Right []` ⇒ `"no matches"`, not an error.
- `preview` boundedness: size independent of array length / nesting depth.

## 7. Downstream (not built here)

This unlocks the **E1 reframe**: compacting-coalgebra vs reference-coalgebra as
a bake-off (per-component `Behaviour` divergence + prefix-stability + evaluated-
token cost), rather than E1's current "how defective is compaction". Named
here; `[unbuilt]`.

## 8. Risks

- **Over-expansion**: a model that `deref`s everything re-floods the context and
  can still trip `Overflow` → the retained compaction fallback catches it.
  `bCalls` (oracle/round-trip count) is the metric to watch. `[speculative]`
- **`Obs` ripple**: the product change touches every construction site; large
  but mechanical surface area, caught by the compiler and the suite.
- **Threshold tuning**: `previewThreshold` is a guess; it is the one knob that
  wants empirical tuning for a given local model/window. `[design]`
