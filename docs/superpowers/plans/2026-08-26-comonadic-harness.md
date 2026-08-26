# Comonadic Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the `comonadic-harness` scoping sketch into a proper, warning-clean Haskell project — a polynomial coalgebra denoted by a cofree comonad, with a unified interpreter, law tests, and a real Ollama/Qwen provider on `hq`.

**Architecture:** One closed interface functor `HarnessF` (three constructors); a coalgebra `step :: S -> HarnessF S`; `unfold` into `Cofree HarnessF Ctx`; and a **single** monad-parameterised interpreter `interp` that both `run` (effectful, in `IO`) and `probe` (pure, fuel-limited `Writer [Ev]`) factor through — so their agreement is free by construction. Execution consumes the tree's *shape*; analysis consumes its *annotation*.

**Tech Stack:** GHC (nixpkgs `haskellPackages`), `comonad`, `free` (`Control.Comonad.Cofree`), `optics-core` (`Optics.Generic`, no TH), `aeson`, `QuickCheck`, `ollama-haskell >= 0.4.1.0`. Nix flake + direnv, mirroring `vf-haskell`.

**Authority:** `BRIEF.md` (design), `TASKS.md` (T1–T7 acceptance criteria), `CLAUDE.md` (five invariants + provenance tags), and the design spec at `docs/superpowers/specs/2026-08-26-comonadic-harness-module-design.md`. The read-only source being ported lives in `reference/Oracle.hs` (the primary), `reference/Harness.hs` (source of `compact`, `outerLoop`, `respectsBehaviour`), and `reference/Run.hs`. Recorded target trace: `runs/oracle-output.txt`.

**Five invariants (never violate):**
1. Alphabet is closed — no wildcard `case` over `HarnessF` in `interp` or tests; `-Wincomplete-patterns` must fire when a constructor is added.
2. Execution never reads the annotation to *choose a successor*. `interp` may read `Ctx` only to *label an event*; the direction always comes from applying the continuation to the oracle/world result.
3. `Cofree` is a denotation — never serialised, cached, or handed to the provider.
4. Evolution lives outside the functor — fold-then-reunfold, never an `Evolve` constructor.
5. Transient failure never reaches the coalgebra — handled by `ollama-haskell`'s retry; only `Overflow` and terminal decode failures are `Refusal`.

**British spelling in prose/comments. Haddock on every exported type/function saying *why* it exists. Carry `[established]`/`[design]`/`[speculative]`/`[unbuilt]` tags into non-obvious comments.**

---

## File Structure

```
comonadic-harness.cabal   library `harness`, exe `demo`, test `spec`
default.nix               callCabal2nix
flake.nix                 devShells + package, pinned nixpkgs
flake.lock                generated
.envrc                    use flake + dotenv_if_exists
hie.yaml                  cabal cradle
src/Harness/
  Alphabet.hs      HarnessF, Call, Obs, Request, Response, Refusal, Outcome, Usage, ToolSpec, Prompt
  State.hs         S, Ctx, Mode, Turn; project, afford, request, view
  Coalgebra.hs     step, working, summarising, harness
  Interp.hs        interp — the ONE case over HarnessF; Ev
  Run.hs           Env, run, mkEnv
  Probe.hs         Hypo, probe, assess, Risk (+ generic Monoid), governed, liftHypo, outcomeOf
  Compaction.hs    compact (idempotent by fiat), Behaviour, observe, respectsBehaviour
  Evolve.hs        evolve, outerLoop
  Tutorial.hs      pipes-style Haddock-only guide (Task 20)
  Motivation.lhs   literate "why" (Task 21)
src/Provider/
  Class.hs         Provider seam
  Ollama.hs        ollama-haskell provider on hq
app/Main.hs        demo, reproduces runs/oracle-output.txt
test/
  Main.hs          hspec/QuickCheck entry
  Gen.hs           reachable-state generators (through public transitions only)
  LawsSpec.hs      agreement, prefix-stability, comonad, affordance, compaction-rate
docs/ollama-notes.md            filled from observation on hq
docs/phase-2-recipe-morphism.md phase-2 stub
```

---

# PHASE A — Foundations (T1, T2)

## Task 1: Cabal stub that builds

**Files:**
- Create: `comonadic-harness.cabal`
- Create: `src/Harness/Alphabet.hs` (minimal stub, fleshed out in Task 4)

- [ ] **Step 1: Write the cabal file**

```cabal
cabal-version:      3.0
name:               comonadic-harness
version:            0.1.0.0
synopsis:           An agentic harness as a polynomial coalgebra denoted by a cofree comonad.
description:        See BRIEF.md. Execution consumes the tree's shape; analysis consumes its annotation.
license:            MIT
author:             Ben Ford
maintainer:         ben@missionctrl.dev
category:           Control, AI
build-type:         Simple
extra-source-files: BRIEF.md, TASKS.md, README.md

common warnings
  ghc-options:
    -Wall -Wcompat -Wincomplete-uni-patterns -Wincomplete-patterns
    -Wredundant-constraints -Wmissing-export-lists

common exts
  default-language: GHC2021
  default-extensions:
    DeriveGeneric DeriveFunctor DeriveTraversable DeriveAnyClass
    DerivingStrategies LambdaCase OverloadedStrings OverloadedRecordDot
    DataKinds TypeApplications

library
  import:           warnings, exts
  hs-source-dirs:   src
  exposed-modules:
    Harness.Alphabet
  build-depends:
      base >= 4.17 && < 5
    , comonad
    , free
    , optics-core
    , containers
    , mtl
    , text
    , bytestring
    , aeson
    , dlist
    , ollama-haskell >= 0.4.1.0

executable demo
  import:           warnings, exts
  hs-source-dirs:   app
  main-is:          Main.hs
  build-depends:    base, comonad-harness-placeholder
  buildable:        False

test-suite spec
  import:           warnings, exts
  type:             exitcode-stdio-1.0
  hs-source-dirs:   test
  main-is:          Main.hs
  build-depends:    base, comonad-harness-placeholder
  buildable:        False
```

> Note: `demo` and `test-suite` are `buildable: False` until Tasks 18/16 wire them; this keeps `cabal build` green from Task 1. The `comonad-harness-placeholder` dep name is deliberately never resolved because `buildable: False` short-circuits it — replaced with real deps when those tasks flip `buildable`.

- [ ] **Step 2: Write the minimal Alphabet stub**

`src/Harness/Alphabet.hs`:

```haskell
module Harness.Alphabet
  ( Prompt (..)
  ) where

-- | Placeholder; fleshed out in the port (Task 4).
newtype Prompt = Prompt String
  deriving stock (Eq, Show)
```

- [ ] **Step 3: Build**

Run: `cabal build harness`
Expected: compiles clean, no warnings. (If `ollama-haskell` fails to resolve, that is Task 2's problem — proceed to Task 2 and return.)

- [ ] **Step 4: Commit**

```bash
git add comonadic-harness.cabal src/Harness/Alphabet.hs
git commit -m "feat(T1): cabal stub + library skeleton builds"
```

**Acceptance (T1):** `cabal build` succeeds on an empty-ish library.

---

## Task 2: Nix flake, direnv, hie.yaml — and vf-haskell's .envrc

**Files:**
- Create: `default.nix`, `flake.nix`, `.envrc`, `hie.yaml`
- Modify: `/home/ben/dev/vf-haskell/.envrc`

- [ ] **Step 1: Write `default.nix`**

```nix
# comonadic-harness/default.nix
{ pkgs }:
pkgs.haskellPackages.callCabal2nix "comonadic-harness" ./. { }
```

- [ ] **Step 2: Write `flake.nix`**

```nix
{
  description = "comonadic-harness — an agentic harness as a polynomial coalgebra";

  inputs = {
    # Pinned to the same rev vf-haskell resolves, for a known-good dep set.
    nixpkgs.url = "github:NixOS/nixpkgs/0e251e24a4f24e036a084b6b4b2d2491af4167f4";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        harness = import ./. { inherit pkgs; };
      in {
        packages.default = harness;
        # Cabal dev/test shell: GHC with every lib+test dep of the package
        # (via `.env`) plus tooling. `ollama` is NOT here — it runs on hq.
        devShells.dev = harness.env.overrideAttrs (old: {
          nativeBuildInputs = (old.nativeBuildInputs or []) ++ [
            pkgs.cabal-install
            pkgs.haskell-language-server
            pkgs.fourmolu
            pkgs.curl
            pkgs.jq
          ];
        });
        devShells.default = self.devShells.${system}.dev;
      });
}
```

- [ ] **Step 3: Write `.envrc` and `hie.yaml`**

`.envrc`:
```bash
use flake
dotenv_if_exists .env
```

`hie.yaml`:
```yaml
cradle:
  cabal:
    - path: "./src"
      component: "lib:comonadic-harness"
    - path: "./app"
      component: "exe:demo"
    - path: "./test"
      component: "test:spec"
```

- [ ] **Step 4: Generate the lock and enter the shell**

Run: `nix flake lock && direnv allow && nix develop .#dev --command cabal build harness`
Expected: lockfile generated; `cabal build` succeeds inside the shell.

> If `ollama-haskell 0.4.1.0` is absent from the pinned `haskellPackages`, add it in `default.nix` via `haskellPackages.callHackageDirect`, e.g.:
> ```nix
> { pkgs }:
> let hp = pkgs.haskellPackages.override {
>       overrides = self: super: {
>         ollama-haskell = self.callHackageDirect {
>           pkg = "ollama-haskell"; ver = "0.4.1.0"; sha256 = "";  # fill sha
>         } {};
>       };
>     };
> in hp.callCabal2nix "comonadic-harness" ./. { }
> ```
> Get the sha256 from the first failing build's "hash mismatch" message.

- [ ] **Step 5: Verify the remote Ollama is reachable from the shell**

Run: `nix develop .#dev --command curl -s http://hq:11434/api/tags | jq '.models[].name'`
Expected: a JSON list of model names from `hq`. Record the exact Qwen tag you see; it becomes the provider default (Task 17) and goes in `docs/ollama-notes.md`.

- [ ] **Step 6: Add vf-haskell's .envrc (separate, scoped change)**

Set the contents of `/home/ben/dev/vf-haskell/.envrc` to:
```bash
use flake
dotenv_if_exists .env
```
Run: `cd /home/ben/dev/vf-haskell && direnv allow && cd -`
Expected: no error; vf-haskell's flake dev shell now auto-loads.

- [ ] **Step 7: Commit (two repos)**

```bash
git add default.nix flake.nix flake.lock .envrc hie.yaml
git commit -m "feat(T2): nix flake + direnv dev shell; hq ollama reachable"
git -C /home/ben/dev/vf-haskell add .envrc
git -C /home/ben/dev/vf-haskell commit -m "chore: add 'use flake' .envrc for auto-loading dev shell"
```

**Acceptance (T2):** `nix develop` gives a shell where `cabal build` works and `curl http://hq:11434/api/tags` returns the model list.

---

# PHASE B — The port (T3)

Port `reference/Oracle.hs` (primary) plus `compact`/`outerLoop`/`respectsBehaviour` from `reference/Harness.hs` into `src/Harness/*`. This is a rewrite: real `free`/`comonad`, `Generic` on every record and sum, `Optics.Generic` in state transitions, and the **unified `interp`**.

## Task 3: Behaviour-preserving baseline — build the demo against the reference first

**Files:**
- Create: `app/Main.hs` (temporary shim), toggling nothing yet — SKIP. Instead establish the target trace.

- [ ] **Step 1: Produce the reference trace to diff against later**

Run:
```bash
cd reference && ghc -Wall -O0 -main-is Oracle.main Oracle.hs Harness.hs -o /tmp/oracle-ref && /tmp/oracle-ref > /tmp/oracle-ref.txt; cd ..
diff /tmp/oracle-ref.txt runs/oracle-output.txt && echo "TRACE MATCHES COMMITTED"
```
Expected: the reference compiles and its output matches `runs/oracle-output.txt` (this is the trace Task 18 must reproduce modulo formatting). If it differs, the committed trace is stale — note it; the target is the *committed* file per T3.

- [ ] **Step 2: Commit nothing** (verification only). Proceed.

---

## Task 4: `Harness.Alphabet` — the closed interface functor

**Files:**
- Modify: `src/Harness/Alphabet.hs` (replace the stub)
- Modify: `comonadic-harness.cabal` (add module to `exposed-modules`)

Source: `reference/Oracle.hs:30-60`. Changes: add `Generic`/`deriving stock`; keep `HarnessF`'s `Functor` derived.

- [ ] **Step 1: Write the module**

```haskell
{-# LANGUAGE DeriveAnyClass #-}

-- | The closed action alphabet. Three constructors, no escape hatch.
--
-- Positions are what the harness /does/; directions (the function
-- arguments) are what it does /not/ control. The harness is deterministic;
-- all nondeterminism lives in the directions, which is exactly why
-- 'Control.Comonad.Cofree.duplicate' on the unfolded tree is pure and lazy.
-- [established]
module Harness.Alphabet
  ( Prompt (..)
  , ToolSpec (..)
  , Request (..)
  , Call (..)
  , Obs (..)
  , Usage (..)
  , Response (..)
  , Refusal (..)
  , Outcome (..)
  , HarnessF (..)
  ) where

import GHC.Generics (Generic)

newtype Prompt = Prompt String
  deriving stock (Eq, Show, Generic)

-- | A tool the provider is told it may call. Carried in the 'Request' so it
-- actually reaches the model — the amendment 'reference/Harness.hs' lacked.
data ToolSpec = ToolSpec { specName :: String, specSchema :: String }
  deriving stock (Eq, Show, Generic)

-- | What the model sees: the projected prompt plus the mode-dependent tools.
data Request = Request { reqPrompt :: Prompt, reqTools :: [ToolSpec] }
  deriving stock (Eq, Show, Generic)

data Call = Call { tool :: String, args :: String }
  deriving stock (Eq, Show, Generic)

newtype Obs = Obs String
  deriving stock (Eq, Show, Generic)

-- | Token usage as reported by the provider. Budget is spent in tokens,
-- not turns. [established]
data Usage = Usage { inTok :: Int, outTok :: Int }
  deriving stock (Eq, Show, Generic)

data Response = Response { say :: String, calls :: [Call], usage :: Usage }
  deriving stock (Eq, Show, Generic)

-- | The only failures the coalgebra may see. Everything transient (429, 5xx,
-- socket timeouts) is the provider's problem and never gets here (invariant 5).
data Refusal = Overflow | Malformed String
  deriving stock (Eq, Show, Generic)

data Outcome = Done String | Exhausted | Stuck String
  deriving stock (Eq, Show, Generic)

-- | The interface functor. Closed. A fourth constructor requires a matching
-- case in 'Harness.Interp.interp' and the law tests, or @-Wincomplete-patterns@
-- will (correctly) fail the build.
data HarnessF x
  = Render Request (Either Refusal Response -> x)
  | Perform Call (Obs -> x)
  | Halt Outcome
  deriving stock (Functor, Generic)
```

- [ ] **Step 2: Add to cabal** `exposed-modules:` — replace the single `Harness.Alphabet` line with the full list from the File Structure section as you create each module. For now just `Harness.Alphabet`.

- [ ] **Step 3: Build** — Run: `cabal build harness` — Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add src/Harness/Alphabet.hs comonadic-harness.cabal
git commit -m "feat(T3): Harness.Alphabet — closed interface functor with Generic"
```

---

## Task 5: `Harness.State` — state and the three quotients

**Files:**
- Create: `src/Harness/State.hs`; add to `exposed-modules`

Source: `reference/Oracle.hs:62-117`. Changes: `Generic` everywhere; keep `project`/`afford`/`request`/`view` as-is (they are already the quotients). Add a Haddock note on `project`'s prefix-stability law (§16.6) — the thing Task 15 tests.

- [ ] **Step 1: Write the module**

```haskell
-- | The harness state @S@ and the three quotients on it:
-- @project@ (lossy, what the model sees), the affordance fold, and @view@
-- (the annotation placed on every tree node).
module Harness.State
  ( Mode (..)
  , Turn (..)
  , S (..)
  , Ctx (..)
  , project
  , allTools
  , afford
  , request
  , view
  , renderLine
  ) where

import GHC.Generics (Generic)
import Harness.Alphabet

data Mode = Working | Summarising
  deriving stock (Eq, Show, Generic)

data Turn
  = Assistant Response
  | User [(Call, Obs)]
  | Summary String
  deriving stock (Eq, Show, Generic)

-- | Newest turn first. @mode@ is the bit that lets one 'Render' constructor
-- serve both a task turn and a summarisation turn.
data S = S
  { transcript :: [Turn]
  , pending :: [Call]
  , budget :: Int      -- ^ tokens, not turns
  , mode :: Mode
  }
  deriving stock (Eq, Show, Generic)

-- | The annotation. Read by analysis (@probe@/@governed@), never used by
-- execution to choose a successor (invariant 2).
data Ctx = Ctx { ctxRequest :: Request, ctxBudget :: Int, ctxMode :: Mode }
  deriving stock (Eq, Show, Generic)

-- | Render one turn to a prompt line. Factored out so the prefix-stability
-- law (§16.6) can be stated: in 'Working' mode,
-- @project (t : ts) == project ts <> renderLine t@ (appending a turn appends
-- to the end of the prompt, leaving the cached prefix untouched). [established]
renderLine :: Turn -> String
renderLine (Assistant r) = "A: " ++ say r ++ concatMap (\c -> " <" ++ tool c ++ ">") (calls r)
renderLine (User rs)     = "U: " ++ concatMap (\(c, Obs o) -> tool c ++ "=" ++ o ++ " ") rs
renderLine (Summary t)   = "S: " ++ t

-- | Quotient 1. Lossy, total, recomputed each turn.
project :: S -> Prompt
project s = Prompt (unlines (map renderLine (reverse (transcript s))))

allTools :: [ToolSpec]
allTools =
  [ ToolSpec "read" "{path:string}"
  , ToolSpec "bash" "{cmd:string}"
  , ToolSpec "write" "{path:string,body:string}"
  , ToolSpec "commit" "{msg:string}"
  ]

-- | Mode-dependent affordances — a fold over the transcript, not a constant.
-- This is what makes the interface polynomial. @commit@ is only offered once
-- a @write@ has happened.
afford :: S -> [ToolSpec]
afford s
  | mode s == Summarising = []
  | any wrote (transcript s) = allTools
  | otherwise = filter ((/= "commit") . specName) allTools
  where
    wrote (User rs) = any ((== "write") . tool . fst) rs
    wrote _ = False

-- | In 'Summarising' mode the request carries a summarisation instruction and
-- /no tools/ — so compaction goes through the same 'Render' constructor.
request :: S -> Request
request s = case mode s of
  Working -> Request (project s) (afford s)
  Summarising ->
    let Prompt p = project s
     in Request (Prompt (p ++ "\n[summarise the above in one line]")) []

view :: S -> Ctx
view s = Ctx (request s) (budget s) (mode s)
```

- [ ] **Step 2: Build** — `cabal build harness` — clean.
- [ ] **Step 3: Commit**

```bash
git add src/Harness/State.hs comonadic-harness.cabal
git commit -m "feat(T3): Harness.State — S, Ctx, and the three quotients"
```

---

## Task 6: `Harness.Coalgebra` — step, with optic-composed transitions

**Files:**
- Create: `src/Harness/Coalgebra.hs`; add to `exposed-modules`

Source: `reference/Oracle.hs:119-158`. Changes: (1) `harness` uses `Control.Comonad.Cofree.unfold` from `free`, whose signature is `unfold :: Functor f => (b -> (a, f b)) -> b -> Cofree f a`; wrap `view`/`step` into that shape. (2) Replace record-update syntax in `working`/`summarising` with `Optics.Generic` composition.

- [ ] **Step 1: Write the module**

```haskell
-- | The coalgebra: the entire control flow of the agent, as a pure case
-- analysis returning a functor of successor states. Compare
-- @naiveTilNoToolCallStep@ in agents-exe — same analysis, but returning the
-- shape rather than an action for a separate driver to interpret.
module Harness.Coalgebra
  ( step
  , working
  , summarising
  , harness
  ) where

import Control.Comonad.Cofree (Cofree, unfold)
import Optics.Core ((%), (.~), (&), (%~))
import Optics.Generic (gfield)
import Harness.Alphabet
import Harness.State

-- | @step@ is deterministic: it always knows what it does next. What it does
-- not know is what comes back, which is why the successor is a /function/ of
-- the oracle\/world result.
step :: S -> HarnessF S
step s
  | budget s <= 0 = Halt Exhausted
  | otherwise = case pending s of
      (c : cs) ->
        Perform c $ \o ->
          s & gfield @"transcript" %~ record c o
            & gfield @"pending" .~ cs
      [] -> case (mode s, transcript s) of
        (Working, Assistant r : _)
          | null (calls r) -> Halt (Done (say r))
        (Working, _)     -> Render (request s) (working s)
        (Summarising, _) -> Render (request s) (summarising s)
  where
    record c o (User rs : ts) = User (rs ++ [(c, o)]) : ts
    record c o ts             = User [(c, o)] : ts

-- | The 'Working'-mode continuation. Overflow flips to 'Summarising' (the only
-- correct response is a state transition, and the coalgebra is the only thing
-- that can make one). A malformed refusal is terminal.
working :: S -> Either Refusal Response -> S
working s (Left Overflow)      = s & gfield @"mode" .~ Summarising
working s (Left (Malformed m)) =
  s & gfield @"transcript" %~ (Summary ("!" ++ m) :)
    & gfield @"budget" .~ 0
working s (Right r) =
  s & gfield @"transcript" %~ (Assistant r :)
    & gfield @"pending" .~ calls r
    & gfield @"budget" %~ subtract (inTok (usage r) + outTok (usage r))

-- | The 'Summarising'-mode continuation. Success collapses the transcript to a
-- single 'Summary' turn and returns to 'Working'. This is compaction, executed
-- through the ordinary 'Render' path.
summarising :: S -> Either Refusal Response -> S
summarising s (Left _) = s & gfield @"budget" .~ 0
summarising s (Right r) =
  s & gfield @"transcript" .~ [Summary (say r)]
    & gfield @"mode" .~ Working
    & gfield @"budget" %~ subtract (inTok (usage r) + outTok (usage r))

-- | The only constructor for a harness: an annotation and a coalgebra, unfolded.
-- No @Cofree HarnessF Ctx@ exists that is not generated by some coalgebra.
harness :: S -> Cofree HarnessF Ctx
harness = unfold (\s -> (view s, step s))
```

> If `gfield`/optic composition fights the type checker on the sum-typed
> `transcript` update, fall back to record-update syntax for that one field and
> leave a `-- [design] optic composition declined here: ...` comment. The optic
> rewrite is a readability goal, not a correctness one; do not burn the task on it.
> `(&)` and `(%~)`/`(.~)` come from `optics-core`; remove the unused `(%)` import if HLS flags it.

- [ ] **Step 2: Build** — `cabal build harness` — clean (no unused-import warnings).
- [ ] **Step 3: Commit**

```bash
git add src/Harness/Coalgebra.hs comonadic-harness.cabal
git commit -m "feat(T3): Harness.Coalgebra — step + optic-composed transitions"
```

---

## Task 7: `Harness.Interp` — the ONE interpreter (defect D9)

**Files:**
- Create: `src/Harness/Interp.hs`; add to `exposed-modules`

This is the single highest-value change (§16.1). `run` and `probe` both factor through `interp`; there is exactly one `case` over `HarnessF` in the whole project.

- [ ] **Step 1: Write the failing intent as a Haddock-documented module**

```haskell
-- | The single interpreter over the alphabet. Both 'Harness.Run.run' (in @IO@)
-- and 'Harness.Probe.probe' (pure, fuel-limited) are instances of it, so the
-- law that they agree is free by construction rather than maintained by
-- inspection across two hand-written case analyses (defect D9, §16.1).
--
-- The interpreter emits one 'Ev' per node into a 'Control.Monad.Writer' and
-- respects a depth bound. Both are monadic effects, not extra constructors.
-- Reading @Ctx@ here only /labels/ an event; the successor is always
-- @k result@, never a function of the annotation (invariant 2).
module Harness.Interp
  ( Ev (..)
  , interp
  ) where

import Control.Comonad.Cofree (Cofree ((:<)))
import Control.Monad.Writer (MonadWriter, tell)
import Harness.Alphabet
import Harness.State (Ctx (..), Mode)

-- | An observation of one interpreter step. @Asked@ carries the mode so the
-- summarisation turns are distinguishable in a trace.
data Ev = Asked Mode | Refused Refusal | Did Call | Ended Outcome
  deriving stock (Eq, Show)

-- | @interp askOracle askWorld fuel tree@ walks the tree, performing the
-- (possibly effectful) oracle/world actions, until it 'Halt's or runs out of
-- fuel. Returns @Just outcome@ on halt, @Nothing@ if fuel is exhausted first.
--
-- The three cases below are exhaustive and wildcard-free: adding a 'HarnessF'
-- constructor must break this build (invariant 1).
interp
  :: MonadWriter [Ev] m
  => (Request -> m (Either Refusal Response))
  -> (Call -> m Obs)
  -> Int
  -> Cofree HarnessF Ctx
  -> m (Maybe Outcome)
interp askOracle askWorld = go
  where
    go _ (_ :< Halt o) = Just o <$ tell [Ended o]
    go n _ | n <= 0 = pure Nothing
    go n (c :< Render q k) = do
      tell [Asked (ctxMode c)]
      r <- askOracle q
      case r of
        Left e -> tell [Refused e]
        Right _ -> pure ()
      go (n - 1) (k r)
    go n (_ :< Perform call k) = do
      tell [Did call]
      o <- askWorld call
      go (n - 1) (k o)
```

- [ ] **Step 2: Build** — `cabal build harness` — clean. Confirm `-Wincomplete-patterns` is on and silent (the three cases are total).
- [ ] **Step 3: Commit**

```bash
git add src/Harness/Interp.hs comonadic-harness.cabal
git commit -m "feat(T3): Harness.Interp — unified interpreter, the only case over HarnessF (D9)"
```

---

## Task 8: `Harness.Run` — run as an instance of interp

**Files:**
- Create: `src/Harness/Run.hs`; add to `exposed-modules`

Source: `reference/Oracle.hs:160-172` (the `Env`) plus the new factoring. `withRetry` is dropped — retry belongs to the provider (invariant 5, Task 17).

- [ ] **Step 1: Write the module**

```haskell
-- | Running a harness: pair the tree against an effectful environment. @run@ is
-- @interp@ over the real oracle and world, in @WriterT@ over @IO@ with the
-- event trace discarded — execution consumes the shape, not the annotation.
module Harness.Run
  ( Env (..)
  , run
  ) where

import Control.Comonad.Cofree (Cofree)
import Control.Monad.Writer (runWriterT)
import Harness.Alphabet
import Harness.Interp (Ev, interp)
import Harness.State (Ctx)

-- | The provider seam and the world seam. The LLM lives in exactly one field.
data Env m = Env
  { oracle :: Request -> m (Either Refusal Response)
  , world  :: Call -> m Obs
  }

-- | Drive the harness to termination. Fuel is 'maxBound': a real run halts on
-- 'Halt', never on fuel. A @Nothing@ (fuel exhausted) is impossible here and
-- maps to @Stuck@ defensively.
run :: Env IO -> Cofree HarnessF Ctx -> IO Outcome
run env w = do
  (mo, _evs :: [Ev]) <-
    runWriterT (interp (oracle env) (world env) maxBound w)
  pure (maybe (Stuck "fuel exhausted") id mo)
```

> The `oracle`/`world` fields are `IO`-valued but `interp` needs them in
> `WriterT [Ev] IO`. GHC lifts them automatically because `WriterT [Ev] IO` has
> a `MonadIO`/lifting path only if you wrap: if it does not infer, change the
> two arguments to `\q -> lift (oracle env q)` and `\c -> lift (world env c)`
> with `Control.Monad.Trans.Class (lift)`. Add `ScopedTypeVariables` to the
> module for the `:: [Ev]` annotation.

- [ ] **Step 2: Build** — `cabal build harness` — clean.
- [ ] **Step 3: Commit**

```bash
git add src/Harness/Run.hs comonadic-harness.cabal
git commit -m "feat(T3): Harness.Run — run as interp over IO, trace discarded"
```

---

## Task 9: `Harness.Probe` — probe/assess/Risk/governed

**Files:**
- Create: `src/Harness/Probe.hs`; add to `exposed-modules`

Source: `reference/Oracle.hs:229-268`. Changes: `probe` = `interp` in pure `Writer` (D9); `Risk`'s `Monoid` derived generically (§16.3); add `liftHypo` and `outcomeOf` for the agreement law (Task 14).

- [ ] **Step 1: Write the module**

```haskell
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingVia #-}

-- | Counterfactual analysis. The tree branches on things you do not control,
-- so you cannot fold it — but you can fold it under a 'Hypo', a pure stand-in
-- for the oracle and world, which collapses the branching to a path.
module Harness.Probe
  ( Hypo (..)
  , probe
  , Risk (..)
  , assess
  , governed
  , liftHypo
  , outcomeOf
  ) where

import Control.Comonad.Cofree (Cofree)
import Control.Comonad (extend)
import Control.Monad.Writer (execWriter)
import Data.Monoid (Sum (..), Any (..))
import GHC.Generics (Generic)
import Harness.Alphabet
import Harness.Interp (Ev (..), interp)
import Harness.State (Ctx)
import Harness.Run (Env (..))

-- | A pure model of the oracle and the world. As crude or as sharp as you like;
-- the forecast is only ever as good as this.
data Hypo = Hypo
  { guessOracle :: Request -> Either Refusal Response
  , guessWorld  :: Call -> Obs
  }

-- | Drive the harness purely to a bounded depth, collecting the event trace.
-- One line, because it is just 'interp' in the 'Writer' monad. [established]
probe :: Hypo -> Int -> Cofree HarnessF Ctx -> [Ev]
probe h n w =
  execWriter (interp (pure . guessOracle h) (pure . guessWorld h) n w)

-- | A forward-looking assessment of a node's own future. Every field carries a
-- monoid, so the 'Monoid' instance derives generically (§16.3) — which is what
-- makes the D1 scan rewrite (Task 19) possible.
data Risk = Risk
  { stepsAhead :: Sum Int
  , terminates :: Any
  , irreversible :: [String]
  , compactions :: Sum Int
  }
  deriving stock (Eq, Show, Generic)
  deriving (Semigroup, Monoid) via GenericMonoid Risk

assess :: Hypo -> Int -> Cofree HarnessF Ctx -> Risk
assess h n w =
  Risk
    { stepsAhead = Sum (length evs)
    , terminates = Any (any ended evs)
    , irreversible = [tool c | Did c <- evs, tool c `elem` ["write", "commit"]]
    , compactions = Sum (length [() | Refused Overflow <- evs])
    }
  where
    evs = probe h n w
    ended (Ended _) = True
    ended _ = False

-- | Annotate every reachable state with an assessment of its own future.
-- @extract (governed h 32 w)@ is the pre-action gate at the current node.
governed :: Hypo -> Int -> Cofree HarnessF Ctx -> Cofree HarnessF Risk
governed h n = extend (assess h n)

-- | Turn a 'Hypo' into a pure 'Env', so the agreement law (§16.1, Task 14) can
-- compare @run (liftHypo h)@ against @outcomeOf (probe h n)@.
liftHypo :: Applicative m => Hypo -> Env m
liftHypo h = Env (pure . guessOracle h) (pure . guessWorld h)

-- | The terminal outcome of a trace, if it halted within the horizon.
outcomeOf :: [Ev] -> Maybe Outcome
outcomeOf evs = case [o | Ended o <- evs] of
  (o : _) -> Just o
  []      -> Nothing
```

> `GenericMonoid` is from `generic-data` (add `generic-data` to
> `build-depends`) — it derives a product `Monoid` from per-field monoids. If you
> prefer no new dep, hand-write the two instances by lifting each field's
> monoid; but the derivation is the point of §16.3, so prefer the dep.
> `stepsAhead`/`compactions` being `Sum Int` means `.getSum` at read sites.

- [ ] **Step 2: Add `generic-data` to cabal `build-depends`.**
- [ ] **Step 3: Build** — `cabal build harness` — clean.
- [ ] **Step 4: Commit**

```bash
git add src/Harness/Probe.hs comonadic-harness.cabal
git commit -m "feat(T3): Harness.Probe — probe via interp, Risk's Monoid derived (D9, §16.3)"
```

---

## Task 10: `Harness.Compaction` — idempotent compact + product-of-observations law

**Files:**
- Create: `src/Harness/Compaction.hs`; add to `exposed-modules`

Source: `reference/Harness.hs:229-236`. Changes: (1) make `compact` idempotent by fiat (D11); (2) replace `[Ev]`-equality `respectsBehaviour` with a **product of four observations** (D10, §16.2), each an algebra, so a divergence *names its kind*.

- [ ] **Step 1: Write the module**

```haskell
-- | Compaction and its correctness condition. The law: compaction is a
-- coalgebra homomorphism, i.e. invisible in what the agent /does/ (not in what
-- it /sees/ — the prompt must change). We check the observable shadow, and we
-- make that shadow a /product of four coarser observations/ so a divergence
-- names its kind (D10, §16.2) rather than being a bare boolean (D9's cousin).
module Harness.Compaction
  ( compact
  , Behaviour (..)
  , observe
  , respectsBehaviour
  ) where

import Data.List (sort)
import Data.Monoid (Sum (..), Last (..))
import Harness.Alphabet
import Harness.Interp (Ev (..))
import Harness.Probe (Hypo, probe)
import Harness.State
import Harness.Coalgebra (harness)

-- | Collapse the transcript to a summary stand-in. Idempotent by fiat (D11):
-- for @|ts| < 2@ the naive @take 2 ts ++ [User []]@ grows on each application,
-- which under memory pressure is an infinite compaction loop. Guard it.
compact :: S -> S
compact s
  | alreadyCompact (transcript s) = s
  | otherwise = s { transcript = take 2 (transcript s) ++ [User []] }
  where
    alreadyCompact ts = case reverse ts of
      (User [] : _) -> length ts <= 3
      _ -> False

-- | The behavioural observation: four components, each with its own algebra.
-- Two compactions are behaviourally equal iff all four agree.
data Behaviour = Behaviour
  { bHalt     :: Last Outcome          -- ^ does the task end differently?
  , bWrites   :: [String]              -- ^ multiset of irreversible tool names (sorted)
  , bCalls    :: Sum Int               -- ^ oracle call count — did cost change?
  , bTurnSets :: [[String]]            -- ^ per-turn call sets, order-insensitive within a turn
  }
  deriving stock (Eq, Show)

-- | Observe a trace. @bWrites@ and each @bTurnSets@ entry are sorted so that
-- permuting independent calls within a turn is /not/ a divergence (pi runs them
-- in parallel; the trace is a list of multisets, not a list of events, §16.2).
observe :: [Ev] -> Behaviour
observe evs = Behaviour
  { bHalt = Last (listToMaybe [o | Ended o <- evs])
  , bWrites = sort [tool c | Did c <- evs, tool c `elem` ["write", "commit"]]
  , bCalls = Sum (length [() | Asked _ <- evs])
  , bTurnSets = turnSets evs
  }
  where
    listToMaybe = \case { (x:_) -> Just x; [] -> Nothing }
    -- group Did-calls between successive Asked boundaries, sort each group
    turnSets = go []
      where
        go acc (Asked _ : rest) = sort acc : go [] rest
        go acc (Did c : rest)   = go (tool c : acc) rest
        go acc (Refused _ : rest) = go acc rest
        go acc (Ended _ : _)    = [sort acc]
        go acc []               = [sort acc]

-- | Compaction respects behaviour at @s@ when the compacted and uncompacted
-- states observe /identically/. Returns the 'Behaviour' pair so callers can
-- classify /which/ component diverged (Task 16 reports a rate per component).
respectsBehaviour :: Hypo -> Int -> (S -> S) -> S -> (Behaviour, Behaviour)
respectsBehaviour h n k s =
  ( observe (probe h n (harness (k s)))
  , observe (probe h n (harness s))
  )
```

> `Last`/`Sum` are re-exported from `Data.Monoid`. Add `LambdaCase` if not in
> the default set (it is, per the cabal `common exts`).

- [ ] **Step 2: Build** — `cabal build harness` — clean.
- [ ] **Step 3: Commit**

```bash
git add src/Harness/Compaction.hs comonadic-harness.cabal
git commit -m "feat(T3): Harness.Compaction — idempotent compact (D11) + product-observation law (D10)"
```

---

## Task 11: `Harness.Evolve` — fold-then-reunfold

**Files:**
- Create: `src/Harness/Evolve.hs`; add to `exposed-modules`

Source: `reference/Harness.hs:248-270`. Changes: `evolve = unfold`-shaped like Task 6; `terminates` now reads `Any`, so `.getAny`.

- [ ] **Step 1: Write the module**

```haskell
-- | Evolution: the outer loop. Changing the coalgebra cannot be a 'HarnessF'
-- constructor, because the functor must not mention @S@ (invariant 4 — the same
-- wall agents-exe hits with @Evolve (Agent r)@). So evolution is
-- fold-then-reunfold: keep @S@, swap the coalgebra, 'unfold' again.
module Harness.Evolve
  ( evolve
  , outerLoop
  ) where

import Control.Comonad.Cofree (Cofree, unfold)
import Data.Monoid (Any (..))
import Harness.Alphabet
import Harness.State (Ctx, S)
import Harness.Run (Env, run)
import Harness.Probe (Hypo, Risk (..), assess)

-- | Unfold a chosen coalgebra from a seed.
evolve :: (S -> Ctx) -> (S -> HarnessF S) -> S -> Cofree HarnessF Ctx
evolve v k = unfold (\s -> (v s, k s))

-- | Try successively weaker coalgebras; run the first whose /forecast/ says it
-- terminates (reading the future of a machine that has not been run). This is
-- destruction–creation with a computed trigger, not a guessed one.
outerLoop
  :: Env IO
  -> Hypo
  -> [(S -> Ctx, S -> HarnessF S)]
  -> S
  -> IO Outcome
outerLoop _ _ [] _ = pure (Stuck "no coalgebra left")
outerLoop env h ((v, k) : rest) s =
  let w = evolve v k s
   in if getAny (terminates (assess h 32 w))
        then run env w
        else outerLoop env h rest s
```

- [ ] **Step 2: Build** — `cabal build harness` — clean.
- [ ] **Step 3: Commit**

```bash
git add src/Harness/Evolve.hs comonadic-harness.cabal
git commit -m "feat(T3): Harness.Evolve — fold-then-reunfold outer loop"
```

---

# PHASE C — Law tests (T4)

## Task 12: Test harness wiring + reachable-state generator

**Files:**
- Create: `test/Main.hs`, `test/Gen.hs`
- Modify: `comonadic-harness.cabal` — flip `test-suite spec` to real deps and `buildable: True`

**Generator discipline (§16.7): never construct an `S` by filling the record.** Generate a sequence of oracle/world responses, run the harness under a *generated* `Hypo`, and take the reachable states it produces.

- [ ] **Step 1: Replace the `test-suite spec` stanza**

```cabal
test-suite spec
  import:           warnings, exts
  type:             exitcode-stdio-1.0
  hs-source-dirs:   test
  main-is:          Main.hs
  other-modules:    Gen, LawsSpec
  build-depends:
      base, comonadic-harness, hspec, QuickCheck
    , comonad, free, mtl, containers
```

- [ ] **Step 2: Write `test/Gen.hs`**

```haskell
module Gen
  ( genHypo
  , reachableStates
  , startState
  ) where

import Test.QuickCheck
import Control.Comonad.Cofree (Cofree ((:<)))
import Harness.Alphabet
import Harness.State
import Harness.Coalgebra (harness)
import Harness.Probe (Hypo (..))

-- | A public, reachable starting state. The ONLY hand-written S allowed, and it
-- is the genuine initial state, not a mid-run fabrication.
startState :: Int -> S
startState b = S { transcript = [], pending = [], budget = b, mode = Working }

-- | Generate a pure oracle/world model. Responses vary by prompt length so runs
-- actually progress and sometimes overflow.
genHypo :: Gen Hypo
genHypo = do
  overflowAt <- choose (3, 8)
  tokIn <- choose (80, 200)
  toolChoice <- elements ["read", "write", "bash", "commit"]
  pure Hypo
    { guessOracle = \(Request (Prompt p) tools) ->
        if null tools
          then Right (Response "summary" [] (Usage 300 20))
          else if length (lines p) >= overflowAt
                 then Left Overflow
                 else Right (Response "step" [Call toolChoice "x"] (Usage tokIn 40))
    , guessWorld = \c -> Obs (tool c ++ ":ok")
    }

-- | The states a run actually visits, under a generated hypo, bounded in depth.
-- Walks the tree by applying the generated hypo at each node — the same path
-- 'probe' would take — and yields each S-annotated node's Ctx-bearing subtree.
reachableStates :: Hypo -> Int -> Int -> [Cofree HarnessF Ctx]
reachableStates h fuel b = walk fuel (harness (startState b))
  where
    walk 0 _ = []
    walk n w@(_ :< f) = w : case f of
      Halt _        -> []
      Render q k    -> walk (n - 1) (k (guessOracle h q))
      Perform c k   -> walk (n - 1) (k (guessWorld h c))
```

- [ ] **Step 3: Write a placeholder `test/Main.hs`**

```haskell
module Main (main) where

import Test.Hspec
import qualified LawsSpec

main :: IO ()
main = hspec LawsSpec.spec
```

- [ ] **Step 4: Write a one-line `test/LawsSpec.hs` stub so it compiles**

```haskell
module LawsSpec (spec) where

import Test.Hspec

spec :: Spec
spec = describe "laws" $ it "placeholder" $ True `shouldBe` True
```

- [ ] **Step 5: Build & run** — Run: `cabal test spec` — Expected: 1 example, 0 failures.
- [ ] **Step 6: Commit**

```bash
git add test/ comonadic-harness.cabal
git commit -m "feat(T4): test wiring + reachable-state generator (§16.7)"
```

---

## Task 13: Comonad laws at bounded depth

**Files:**
- Modify: `test/LawsSpec.hs`

- [ ] **Step 1: Add the comonad-law properties** (replace the placeholder `spec`)

```haskell
module LawsSpec (spec) where

import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
import Control.Comonad (extract, duplicate, extend)
import Control.Comonad.Cofree (Cofree)
import Harness.Alphabet
import Harness.State (Ctx)
import Gen

-- Compare trees by their first-n annotations under a fixed hypo walk.
annots :: Int -> Hypo -> Cofree HarnessF Ctx -> [Ctx]
annots n h = map extractHead . reachableFrom
  where
    reachableFrom w = takeWalk n h w
    extractHead = extract

spec :: Spec
spec = describe "laws" $ do
  describe "comonad (Cofree HarnessF Ctx), bounded depth" $ do
    prop "extract . duplicate == id" $
      forAll genHypo $ \h -> forAll (choose (100, 1200)) $ \b ->
        let w = head (reachableStates h 20 b)
         in extract (duplicate w) `eqTree` w
    prop "fmap extract . duplicate == id" $
      forAll genHypo $ \h -> forAll (choose (100, 1200)) $ \b ->
        let w = head (reachableStates h 20 b)
         in annots 12 h (fmap extract (duplicate w)) == annots 12 h w
  where
    -- structural equality up to bounded depth via annotation walk
    eqTree a c = annots 12 undefinedHypo a == annots 12 undefinedHypo c
    undefinedHypo = error "replaced below"
```

> The `eqTree`/`undefinedHypo` shape above is a sketch — replace `eqTree` with a
> concrete bounded structural compare that threads the *same* generated `h`
> (add `takeWalk :: Int -> Hypo -> Cofree HarnessF Ctx -> [Cofree HarnessF Ctx]`
> to `Gen.hs`, identical body to `reachableStates`' `walk` but starting from an
> arbitrary node). The property is: comparing the annotation stream of `w` and
> of the reconstructed tree, under one hypo, to depth 12, they are equal. Keep it
> wildcard-free.

- [ ] **Step 2: Add `takeWalk` to `Gen.hs`** (export it) — same body as `walk`, taking a start node.
- [ ] **Step 3: Run** — `cabal test spec` — Expected: comonad props pass.
- [ ] **Step 4: Commit**

```bash
git add test/LawsSpec.hs test/Gen.hs
git commit -m "test(T4): comonad laws at bounded depth"
```

---

## Task 14: The agreement law (§16.1) — free by construction, asserted as a guard

**Files:**
- Modify: `test/LawsSpec.hs`

- [ ] **Step 1: Add the property**

```haskell
    describe "agreement (run == probe outcome), the value proposition" $
      prop "outcomeOf (probe h n w) == run (liftHypo h) w, at halting depth" $
        forAll genHypo $ \h -> forAll (choose (200, 1200)) $ \b -> ioProperty $ do
          let w = head (reachableStates h 64 b)
          ranOutcome <- run (liftHypo h) w
          let probed = outcomeOf (probe h 64 w)
          pure (probed == Just ranOutcome)
```

Imports to add: `Harness.Run (run)`, `Harness.Probe (probe, liftHypo, outcomeOf)`.

- [ ] **Step 2: Run** — `cabal test spec` — Expected: PASS. (If it fails, `interp` was re-split — a genuine regression, fix the interpreter, do not weaken the test.)
- [ ] **Step 3: Commit**

```bash
git add test/LawsSpec.hs
git commit -m "test(T4): agreement law run==probe as a regression guard (§16.1)"
```

---

## Task 15: Prefix stability (§16.6)

**Files:**
- Modify: `test/LawsSpec.hs`

- [ ] **Step 1: Add the property** — in `Working` mode, appending a turn appends to the prompt end.

```haskell
    describe "prefix stability (protects prompt caching, §16.6)" $
      prop "project (t:ts) == project ts <> renderLine t, Working mode" $
        forAll genTurns $ \ts -> forAll genTurn $ \t ->
          let Prompt whole = project (mkWorking (t : ts))
              Prompt rest  = project (mkWorking ts)
           in whole == rest ++ renderLine t ++ "\n"
  where
    mkWorking ts = S { transcript = ts, pending = [], budget = 1, mode = Working }
```

Add generators `genTurn :: Gen Turn` and `genTurns :: Gen [Turn]` to `Gen.hs` (build `Assistant`/`User`/`Summary` from small random strings). Imports: `Harness.State (project, renderLine, S(..), Mode(..), Turn(..))`, `Harness.Alphabet (Prompt(..))`.

> Note the trailing `"\n"`: `project` uses `unlines`, which appends a newline
> per line. Verify the exact concatenation against `unlines`' behaviour; adjust
> the RHS to match rather than changing `project`.

- [ ] **Step 2: Run** — `cabal test spec` — Expected: PASS.
- [ ] **Step 3: Commit**

```bash
git add test/LawsSpec.hs test/Gen.hs
git commit -m "test(T4): prefix-stability law (§16.6)"
```

---

## Task 16: Compaction violation-rate — the deliverable, expected to fail informatively

**Files:**
- Modify: `test/LawsSpec.hs`

Report a **rate** with a **per-component breakdown** over ≥1000 reachable states, not a boolean. Baseline: no-op `compact` scores 0%.

- [ ] **Step 1: Add a rate-measuring test (not a `prop`, an `it` that computes and prints)**

```haskell
  describe "compaction violation rate (E1, expected non-zero)" $ do
    it "no-op compaction scores 0% (baseline null model)" $ do
      rate <- measureRate id
      totalPct rate `shouldBe` 0
    it "real compaction: report rate + per-component breakdown" $ do
      rate <- measureRate compact
      -- informational: print the classified breakdown, assert only that the
      -- harness did not crash producing it.
      putStrLn (renderRate rate)
      totalPct rate `shouldSatisfy` (>= 0)
```

- [ ] **Step 2: Implement `measureRate`/`renderRate`/`totalPct`** in `LawsSpec.hs`:

```haskell
data Rate = Rate
  { nStates :: Int
  , diffHalt :: Int
  , diffWrites :: Int
  , diffCalls :: Int
  , diffTurns :: Int
  } deriving Show

measureRate :: (S -> S) -> IO Rate
measureRate k = do
  samples <- generate (vectorOf 40 genHypo)   -- 40 hypos ...
  let states = [ (h, w)
               | h <- samples
               , w <- reachableStates h 40 900 ]  -- ... × reachable states ≥ 1000 total
      obs (h, w) =
        let (a, b) = respectsBehaviour h 40 k (stateOf w)
        in ( bHalt a /= bHalt b
           , bWrites a /= bWrites b
           , bCalls a /= bCalls b
           , bTurnSets a /= bTurnSets b )
      rs = map obs states
  pure Rate
    { nStates = length rs
    , diffHalt   = length (filter (\(x,_,_,_) -> x) rs)
    , diffWrites = length (filter (\(_,x,_,_) -> x) rs)
    , diffCalls  = length (filter (\(_,_,x,_) -> x) rs)
    , diffTurns  = length (filter (\(_,_,_,x) -> x) rs)
    }

totalPct :: Rate -> Int
totalPct r
  | nStates r == 0 = 0
  | otherwise = (100 * (diffHalt r + diffWrites r + diffCalls r + diffTurns r)) `div` (4 * nStates r)

renderRate :: Rate -> String
renderRate r = unlines
  [ "compaction violation rate over " ++ show (nStates r) ++ " reachable states:"
  , "  halt outcome differs:   " ++ pct (diffHalt r)
  , "  write multiset differs: " ++ pct (diffWrites r)
  , "  call count differs:     " ++ pct (diffCalls r)
  , "  per-turn sets differ:   " ++ pct (diffTurns r)
  ]
  where pct x | nStates r == 0 = "n/a"
              | otherwise = show (100 * x `div` nStates r) ++ "%"
```

> `stateOf :: Cofree HarnessF Ctx -> S` does not exist — the tree carries `Ctx`,
> not `S`. Two honest options: (a) change `reachableStates` to also return the
> `S` it unfolded from (thread `S` alongside the tree in `Gen.walk`), returning
> `[(S, Cofree HarnessF Ctx)]`; or (b) have `respectsBehaviour` take the seed `S`
> and re-`harness` it (it already does — see Task 10). Option (b): make
> `reachableStates` yield the seed `S` list directly. **Pick (a): change
> `reachableStates` to `[(S, Cofree HarnessF Ctx)]`** and update Task 13's
> callers to `fst`/`snd`. This is the one cross-task signature to keep
> consistent. Do it here and fix Task 13's uses.

- [ ] **Step 3: Run** — `cabal test spec` — Expected: baseline 0%; real compaction prints a classified rate; suite is green (failing *informatively* means reporting the rate, not a red suite — per T4 the deliverable is the number).
- [ ] **Step 4: Commit**

```bash
git add test/LawsSpec.hs test/Gen.hs
git commit -m "test(T4): compaction violation-rate with per-component breakdown (D10/E1)"
```

**Acceptance (T4):** the compaction property runs over ≥1000 reachable generated states and reports a rate with per-component classification.

---

# PHASE D — Provider & demo (T5)

## Task 17: `Provider.Class` + `Provider.Ollama` — the hq oracle

**Files:**
- Create: `src/Provider/Class.hs`, `src/Provider/Ollama.hs`; add both to `exposed-modules`
- Create/append: `docs/ollama-notes.md`

- [ ] **Step 1: Write `Provider.Class`**

```haskell
-- | The provider seam: everything the harness needs from an LLM, and nothing
-- else. An 'Env'\'s @oracle@ is built from one of these. Keeping it abstract
-- lets the pure 'Ollama.Testing' mock and the real client share a type.
module Provider.Class
  ( Provider (..)
  , providerEnv
  ) where

import Harness.Alphabet
import Harness.Run (Env (..))

data Provider m = Provider
  { complete :: Request -> m (Either Refusal Response)
  , act      :: Call -> m Obs
  }

providerEnv :: Provider IO -> Env IO
providerEnv p = Env (complete p) (act p)
```

- [ ] **Step 2: Write `Provider.Ollama`** — translate `Request` ↔ `ollama-haskell`, set `optNumCtx`, map usage, infer overflow.

```haskell
-- | The real provider: Qwen on Ollama, running on hq. Base URL is config
-- (never localhost). @optNumCtx@ is config and deliberately settable low — the
-- single lever that provokes 'Overflow' → compaction cheaply (§12, E1).
module Provider.Ollama
  ( OllamaConfig (..)
  , defaultOllamaConfig
  , ollamaProvider
  ) where

import Data.List.NonEmpty (NonEmpty ((:|)))
import qualified Data.Text as T
import Ollama
  ( Client, chat, chatRequest, userMessage, chatTools, chatOptions
  , Tool (..), FunctionDef (..), FunctionParameters (..)
  , ChatResponse (..), Message (..), defaultOptions, ModelOptions (..)
  , withClient, defaultConfig, OllamaClientConfig (..), ExponentialRetry (..)
  )
import Harness.Alphabet
import Harness.State (afford)  -- if you need it; else translate reqTools directly
import Provider.Class (Provider (..))

data OllamaConfig = OllamaConfig
  { ocBaseUrl :: String   -- ^ e.g. "http://hq:11434"
  , ocModel   :: String   -- ^ exact tag from `ollama list` on hq
  , ocNumCtx  :: Int      -- ^ set LOW to provoke Overflow
  }

defaultOllamaConfig :: OllamaConfig
defaultOllamaConfig = OllamaConfig
  { ocBaseUrl = "http://hq:11434"
  , ocModel   = "qwen3:latest"   -- REPLACE with the tag observed in Task 2 step 5
  , ocNumCtx  = 2048
  }

-- | Build the provider. The world (@act@) is a stub tool-runner for the demo;
-- the point of this task is the oracle.
ollamaProvider :: OllamaConfig -> Client -> Provider IO
ollamaProvider cfg client = Provider
  { complete = \req -> completeWith cfg client req
  , act = \c -> pure (Obs (tool c ++ ":ok"))
  }

completeWith :: OllamaConfig -> Client -> Request -> IO (Either Refusal Response)
completeWith cfg client (Request (Prompt p) tools) = do
  let req = (chatRequest (T.pack (ocModel cfg))
                (userMessage (T.pack p) :| []))
        { chatTools   = Just (map toTool tools)
        , chatOptions = Just defaultOptions { optNumCtx = Just (ocNumCtx cfg) }
        }
  res <- chat client req
  pure (decodeResponse cfg res)
```

> **Three empirical lookups to resolve against the installed `ollama-haskell`
> 0.4.1.0 and the hq server; write findings into `docs/ollama-notes.md`:**
> 1. The exact chat-request field for options (`chatOptions` above is the
>    assumed name) and whether `ModelOptions` is the type `chatOptions` wants.
> 2. `ChatResponse` field names for the reply messages and for usage
>    (`prompt_eval_count`/`eval_count`) — write `decodeResponse` to build
>    `Response { say, calls, usage = Usage inTok outTok }` from them, and to map
>    the model's tool calls to `[Call]`.
> 3. **Overflow presentation.** Send a prompt longer than `ocNumCtx` and observe:
>    does Ollama truncate silently (then infer `Overflow` by comparing the
>    reported prompt-eval count against `ocNumCtx`) or return a decodable error
>    (then map it to `Left Overflow`)? Encode whichever it is in
>    `decodeResponse`. Transient errors from the library's retry must NOT map to
>    `Refusal` (invariant 5) — only overflow and terminal decode failures do.
>
> `toTool :: ToolSpec -> Tool` builds `Tool "function" (FunctionDef { fnName =
> T.pack (specName t), ... })`. Fill `FunctionParameters` from `specSchema` or a
> permissive default; the local model tolerates loose schemas.
>
> Use `withClient defaultConfig { configBaseUrl = ocBaseUrl cfg, configRetry =
> ExponentialRetry 3 1000000 }` to get the `Client` at the call site (demo/tests).

- [ ] **Step 3: Fill `docs/ollama-notes.md`** with: `ollama --version`, the model tag, observed `num_ctx` default, the overflow finding (a or b), and the tool-calling defect rates you see. This file is a T5/T6 deliverable.
- [ ] **Step 4: Build** — `cabal build harness` — clean.
- [ ] **Step 5: Commit**

```bash
git add src/Provider/ docs/ollama-notes.md comonadic-harness.cabal
git commit -m "feat(T5): Ollama provider on hq — optNumCtx, usage mapping, overflow inference"
```

---

## Task 18: `app/Main.hs` — the demo, reproducing the trace

**Files:**
- Create: `app/Main.hs`; flip `executable demo` to real deps + `buildable: True`

- [ ] **Step 1: Real cabal stanza for `demo`**

```cabal
executable demo
  import:           warnings, exts
  hs-source-dirs:   app
  main-is:          Main.hs
  build-depends:    base, comonadic-harness, comonad, free, mtl
```

- [ ] **Step 2: Write `app/Main.hs`** — two runs: a pure/fake run that reproduces `runs/oracle-output.txt`, and (behind an arg) a live `hq` run.

```haskell
module Main (main) where

import System.Environment (getArgs)
import Control.Comonad (extract)
import Ollama (withClient, defaultConfig, OllamaClientConfig (..), ExponentialRetry (..))
import Harness.Alphabet
import Harness.State (S (..), Mode (..), Ctx (..))
import Harness.Coalgebra (harness)
import Harness.Run (Env (..), run)
import Harness.Probe (Hypo (..), assess, probe)
import Provider.Class (providerEnv)
import Provider.Ollama (defaultOllamaConfig, ollamaProvider, OllamaConfig (..))

start :: S
start = S [] [] 1200 Working

main :: IO ()
main = do
  args <- getArgs
  case args of
    ("live":_) -> live
    _          -> demoFake

-- | Reproduce runs/oracle-output.txt with the fake oracle/world. Port the
-- verbose runner from reference/Oracle.hs:300-361 (runVerbose/fakeOracle/
-- fakeWorld/hypo) verbatim into this module or a Demo.Fake helper; it already
-- produces the committed trace.
demoFake :: IO ()
demoFake = putStrLn "TODO: port runVerbose + fakeOracle/fakeWorld/hypo from reference/Oracle.hs"

-- | A live run against Ollama on hq. num_ctx low to provoke Summarising.
live :: IO ()
live = do
  let cfg = defaultOllamaConfig { ocNumCtx = 512 }
  withClient defaultConfig
    { configBaseUrl = ocBaseUrl cfg
    , configRetry = ExponentialRetry 3 1000000 } $ \client -> do
      let env = providerEnv (ollamaProvider cfg client)
      o <- run env (harness start)
      putStrLn ("outcome: " ++ show o)
```

> Replace the `demoFake` stub by porting `runVerbose`, `fakeOracle`, `fakeWorld`,
> and `hypo` from `reference/Oracle.hs:274-361`. The `assess`/`probe` calls there
> now read `Sum`/`Any`-wrapped `Risk` fields, so adjust `stepsAhead`→`.getSum`,
> `terminates`→`.getAny`, `compactions`→`.getSum` in the print line.

- [ ] **Step 3: Reproduce the trace** — Run: `cabal run demo > /tmp/demo.txt && diff /tmp/demo.txt runs/oracle-output.txt`
  Expected: identical modulo formatting/whitespace. If formatting drifted, align the print statements to the committed trace.
- [ ] **Step 4: Commit**

```bash
git add app/Main.hs comonadic-harness.cabal
git commit -m "feat(T3/T5): demo reproduces oracle-output.txt; live hq run behind 'live' arg"
```

- [ ] **Step 5: Live smoke (needs hq reachable)** — Run: `cabal run demo live`
  Expected: completes end-to-end; with `ocNumCtx = 512` the trace visibly enters `Summarising` and returns to `Working` (the `Working → Summarising → Working` path, `oracle-output.txt` nodes 6–8). Record the outcome in `docs/ollama-notes.md`.
- [ ] **Step 6: Commit any notes** — `git add docs/ollama-notes.md && git commit -m "docs(T5): live hq run observations"`

**Acceptance (T5):** a real end-to-end run against hq completes, and a low-`num_ctx` run visibly traverses `Working → Summarising → Working`.

---

# PHASE E — Hardening (T6, T7)

## Task 19: T7/D1 — Risk monoid scan for `governed`

**Files:**
- Modify: `src/Harness/Probe.hs`
- Create: `test/PerfSpec.hs` (add to `other-modules`)

`Risk`'s `Monoid` already exists (Task 9). Under a `Hypo` the tree collapses to a path (a stream), and `extend` on a stream with a monoidal statistic is a `scanr` over `tails`. Along the path a run traverses this is linear; across the whole tree it is not, which does not matter — a run visits one path (§16.3).

- [ ] **Step 1: Add a per-node local statistic and a scan**

```haskell
-- | The one-node contribution to Risk (no re-probe): what THIS node adds.
localRisk :: Hypo -> Cofree HarnessF Ctx -> Risk
localRisk h (_ :< f) = case f of
  Halt o        -> Risk (Sum 1) (Any True) [] (Sum 0)
  Perform c _   -> Risk (Sum 1) (Any False)
                        [tool c | tool c `elem` ["write","commit"]] (Sum 0)
  Render q _    -> case guessOracle h q of
    Left Overflow -> Risk (Sum 1) (Any False) [] (Sum 1)
    _             -> Risk (Sum 1) (Any False) [] (Sum 0)

-- | Accumulated Risk along the hypo path, by a right scan — linear in depth.
governedScan :: Hypo -> Int -> Cofree HarnessF Ctx -> [Risk]
governedScan h n = scanr1 (<>) . map (localRisk h) . takeWalk h n
```

> `takeWalk` is the pure path walk added to `Gen.hs` in Task 13 (the same one
> `probe`/`Gen.walk` use); import it here from `Gen` or, better, promote it into
> a small library module `Harness.Path` so both the test suite and `Probe` share
> one definition. Prefer the shared module to avoid a test-only dependency in
> library code.
> Assert against the old `assess`: `mconcat (map (localRisk h) path) == assess h
> n w` for the path from `w` (they must agree, since `assess` counts exactly
> these contributions). The `Halt` case must match `assess`'s `terminates`/steps
> bookkeeping — reconcile the off-by-one on `stepsAhead` (assess uses
> `length evs`; the scan sums one per node) and adjust `localRisk` so totals
> equal `assess`. This reconciliation IS the deliverable.

- [ ] **Step 2: Write `test/PerfSpec.hs`** — assert `governedScan` agrees with `assess` on totals, and time both against depth (10, 100, 1000) with `System.CPUTime`, printing a before/after curve.
- [ ] **Step 3: Run** — `cabal test spec` — Expected: agreement holds; timing shows the scan flat vs `assess` quadratic. If the monoid totals cannot be reconciled for a statistic you want, **document why in a comment and in `docs/` and keep `assess`** — a recorded negative result is the accepted alternative (T7).
- [ ] **Step 4: Commit**

```bash
git add src/Harness/Probe.hs test/PerfSpec.hs comonadic-harness.cabal
git commit -m "feat(T7): monoidal scan for governed (D1); agreement with assess (§16.3)"
```

**Acceptance (T7):** a before/after wall-clock curve against depth, or a written explanation of why the monoid does not exist.

---

## Task 20: T6/D3 — malformed tool arguments, zero crashes under a hostile oracle

**Files:**
- Modify: `src/Harness/Coalgebra.hs` (validate calls in `step`), `src/Harness/Interp.hs` (no change — stays three cases)
- Create: `test/HostileSpec.hs` (add to `other-modules`)

D3: a schema-invalid tool call is neither `Refusal` nor a clean `Response`. **Decision (argue in a comment): keep the alphabet at three constructors — validate in `step` and feed the validation error back as a synthetic `Obs`.** This is the first option in T6 and keeps the closed alphabet.

- [ ] **Step 1: Add admission + synthetic obs in `step`** — when consuming `pending`, validate each `Call` against `afford s`; an unafforded/invalid call does not `Perform`, it records a synthetic `User [(call, Obs "error: <why>")]` turn and continues, so the model sees its mistake next turn.

```haskell
-- in Harness.Coalgebra, replace the (c:cs) branch of step:
      (c : cs)
        | tool c `elem` map specName (afford s) ->
            Perform c $ \o ->
              s & gfield @"transcript" %~ record c o
                & gfield @"pending" .~ cs
        | otherwise ->   -- D3: unafforded/hallucinated tool. Synthetic error obs.
            Perform c $ \_ ->
              s & gfield @"transcript"
                  %~ record c (Obs ("error: tool not afforded: " ++ tool c))
                & gfield @"pending" .~ cs
```

> This keeps `Perform` (so the world call is skipped via the ignored
> continuation? No — `Perform` still asks the world). Prefer: DON'T `Perform` an
> unafforded call at all — record the synthetic obs directly into the state and
> recurse by returning the NEXT `HarnessF` via a local re-`step`. The cleanest
> shape: filter/repair `pending` at the TOP of `step` (a smart admission pass)
> before the case, so the coalgebra only ever `Perform`s afforded calls. Add
> `admit :: [ToolSpec] -> [Call] -> ([Call], [(Call, Obs)])` returning
> (afforded, rejected-with-synthetic-obs), fold the rejects into the transcript,
> and continue. Implement `admit`; this satisfies the affordance law (D12) too.

- [ ] **Step 2: Add the affordance-law property to `LawsSpec.hs`** — `probe` never emits `Did c` whose tool is absent from the afforded set at that node. (Expected to hold now that `step` admits; it would have failed pre-fix.)
- [ ] **Step 3: Write `test/HostileSpec.hs`** — build a hostile `Env`/`Hypo` (or the pure `Ollama.Testing` mock) emitting hallucinated tool names, malformed args, and empty responses; run to termination; assert `run` returns *some* `Outcome` (no exception) across ≥100 hostile seeds. Use `Control.Exception (try, evaluate)` / `try @SomeException` around `run` and assert `Right`.
- [ ] **Step 4: Run** — `cabal test spec` — Expected: zero crashes; affordance law passes.
- [ ] **Step 5: Commit**

```bash
git add src/Harness/Coalgebra.hs test/HostileSpec.hs comonadic-harness.cabal
git commit -m "feat(T6): admit/repair unafforded calls (D3); affordance law (D12); zero crashes (E4)"
```

**Acceptance (T6):** a hostile `Env` produces zero harness crashes.

---

# PHASE F — Documentation modules

## Task 21: `Harness.Tutorial` — the how (pipes-style)

**Files:**
- Create: `src/Harness/Tutorial.hs`; add to `exposed-modules`

- [ ] **Step 1: Write a Haddock-only tutorial** modelled on `Pipes.Tutorial`:

```haskell
{-# OPTIONS_GHC -fno-warn-unused-imports #-}

-- | (Module-level Haddock: one-paragraph orientation.)
module Harness.Tutorial
  ( -- * Introduction
    -- $introduction

    -- * The closed alphabet
    -- $alphabet

    -- * The coalgebra
    -- $coalgebra

    -- * Shape versus annotation
    -- $shape

    -- * Counterfactual governance
    -- $governed

    -- * Compaction and its law
    -- $compaction
  ) where

import Harness.Alphabet
import Harness.State
import Harness.Coalgebra
import Harness.Interp
import Harness.Run
import Harness.Probe
import Harness.Compaction

{- $introduction
Prose. Use @...@ for inline code and @>>>@ for GHCi sessions. No top-level defs.
-}
-- ... one {- $section -} block per anchor above ...
```

Fill each section with real prose + `@ … @` examples that reference the actual API (so it typechecks against the library). Arc: alphabet → `step` → `unfold` → `run` vs `governed` → `extend` → the compaction law.

- [ ] **Step 2: Build with docs** — Run: `cabal haddock harness` — Expected: renders, no broken `@`-refs.
- [ ] **Step 3: Commit**

```bash
git add src/Harness/Tutorial.hs comonadic-harness.cabal
git commit -m "docs: Harness.Tutorial — pipes-style user guide (how)"
```

---

## Task 22: `Harness.Motivation` (literate) — the why

**Files:**
- Create: `src/Harness/Motivation.lhs`; add to `exposed-modules`

- [ ] **Step 1: Write the literate module** — Bird-style (`>` code), an exposed module `Harness.Motivation`, narrating the derivation and answering the originating question. Real compiling code interleaved with prose.

```
Comonadic agentic harness — why it is what it is.

> module Harness.Motivation where
>
> import Harness.Alphabet
> import Harness.State

The claim: an agentic harness is a durable polynomial coalgebra over a closed
action alphabet ... (prose) ...

Putting the nondeterminism in the directions makes duplicate pure:

> exampleStep :: S -> HarnessF S
> exampleStep = ...   -- a tiny, self-contained illustration that compiles

... continue the narrative from BRIEF §§1,3,5,6 ...
```

Keep every `>` block genuinely compiling (it is a library module). Draw the argument from `BRIEF.md` §§1, 3, 5, 6; do not restate the whole brief — derive the shape and stop.

- [ ] **Step 2: Build** — Run: `cabal build harness` — Expected: the `.lhs` compiles as part of the library.
- [ ] **Step 3: Haddock** — `cabal haddock harness` renders it.
- [ ] **Step 4: Commit**

```bash
git add src/Harness/Motivation.lhs comonadic-harness.cabal
git commit -m "docs: Harness.Motivation — literate 'why it is what it is'"
```

---

## Task 23: Phase-2 stub + README pass

**Files:**
- Create: `docs/phase-2-recipe-morphism.md`
- Modify: `README.md` (point at the built project, not just the sketch)

- [ ] **Step 1: Write `docs/phase-2-recipe-morphism.md`** — sketch only, no code: the intended morphism `VF.Types.Recipe` (`RecipeF`, in vf-haskell) → a `HarnessF`-program; VF value-flow models → executable Petri nets that hand processes (or parts) to the LLM via `Render`/`Perform` and pass the human-required bits back. Name the seam and the open question (human-in-the-loop as a *fourth interpretation* of the alphabet, not a new constructor). Tag everything `[unbuilt]`.
- [ ] **Step 2: Update `README.md`** — add a "Built module" section: `nix develop .#dev`, `cabal test spec`, `cabal run demo`, `cabal run demo live`, and pointers to `Harness.Tutorial`/`Harness.Motivation`.
- [ ] **Step 3: Commit**

```bash
git add docs/phase-2-recipe-morphism.md README.md
git commit -m "docs: phase-2 morphism stub + README build/run instructions"
```

---

## Final verification

- [ ] **Step 1: Full build + test + haddock**

Run: `nix develop .#dev --command bash -c 'cabal build all && cabal test spec && cabal haddock harness'`
Expected: all green; test suite prints the compaction violation-rate breakdown and the governed-scan timing curve.

- [ ] **Step 2: Trace fidelity** — Run: `cabal run demo > /tmp/d.txt && diff /tmp/d.txt runs/oracle-output.txt` — Expected: matches modulo formatting.
- [ ] **Step 3: Closed-alphabet guard** — temporarily add a bogus 4th `HarnessF` constructor; Run: `cabal build harness`; Expected: `-Wincomplete-patterns` fails in `Harness.Interp`. Revert.
- [ ] **Step 4: Commit** any final tidy-ups.

---

## Notes carried from the spec (do not relitigate)

- **Declined:** GADT-indexed alphabet, phantom-tagged `S (m :: Mode)`, indexed monad for balance, promoted units, first-class families (BRIEF §16.8). QuickSpec at most one exploratory run, not a first move.
- **Every experiment needs a baseline null model.** A number without one is not a result.
- **Failing informatively is a deliverable** (the compaction rate, the overflow finding, a negative D1 result) — not a red build to hide.
