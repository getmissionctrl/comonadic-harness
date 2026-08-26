-- | The pure path a run takes under a hypothesis.
--
-- __Why this module exists.__ The 'Cofree' denotation branches at every 'Render'
-- and 'Perform' — one child per possible oracle answer, one per possible
-- observation — because those /directions/ are not under the harness's control.
-- That branching is the whole tree. Fix a 'Hypo' (a pure stand-in for both the
-- oracle and the world) and each node has exactly one child of interest, so the
-- tree collapses to a single path. 'takeWalk' /is/ that collapse.
--
-- __One definition, no drift.__ Both analysis (@Harness.Probe@) and the test
-- generators need \"the path this hypothesis induces\", and they must agree on
-- what it is. Holding the collapse in one place — here, next to 'Hypo' itself —
-- keeps a single referent for the word \"path\" instead of two that could drift.
-- [design]
module Harness.Path
  ( Hypo (..)
  , takeWalk
  ) where

import Control.Comonad.Cofree (Cofree ((:<)))
import Harness.Alphabet
import Harness.State (Ctx)

-- | A pure model of the oracle and the world — the counterfactual \"if the model
-- answered like /this/ and tools behaved like /that/\". It stands in for the two
-- effects a live run supplies from outside ('Harness.Interp.interp's
-- @askOracle@ and @askWorld@), collapsed to pure total functions so a run can be
-- walked with no @IO@ and no live provider. As crude or as sharp as you like:
-- the forecast a 'takeWalk' produces is only ever as good as the 'Hypo' behind
-- it. [design]
--
-- Lives here rather than in @Harness.Probe@ because it is the thing that turns
-- the branching tree into a path — the subject of 'takeWalk' — and both the
-- probe and the generators depend on it.
data Hypo = Hypo
  { guessOracle :: Request -> Either Refusal Response
    -- ^ The pure oracle: how the model would answer a given 'Request'. A
    -- 'Left' models a 'Refusal' ('Overflow' or 'Malformed'); a 'Right' models a
    -- 'Response' (its @say@\/@calls@\/@usage@). This is what a 'Render' branches
    -- on, so it alone decides whether the walk asks for tools, halts, overflows
    -- into summarisation, or dies malformed.
  , guessWorld  :: Call -> Obs
    -- ^ The pure world: the 'Obs' a given tool 'Call' would return. This is what
    -- a 'Perform' branches on. Total by type — it cannot itself refuse or fail;
    -- an unafforded call is handled upstream in the coalgebra's @admit@ pass, not
    -- here.
  }

-- | @takeWalk h fuel tree@ is the list of tree /nodes/ visited when the 'Hypo'
-- @h@ resolves every branch, starting at @tree@'s root and stopping at the first
-- 'Halt' or when @fuel@ nodes have been taken. It yields the whole @Cofree@
-- sub-trees, not just their annotations, so a caller can read either the
-- 'Ctx' at each step (comonad law) or the shape it sits over (the governed
-- scan). [design]
--
-- __How it differs from 'Harness.Interp.interp'.__ Same walk, different output:
-- @interp@ threads a monad, emits an @Harness.Interp.Ev@ trace, and returns the
-- final 'Outcome'; @takeWalk@ is pure structure — it hands back the sequence of
-- nodes and nothing else. Both must agree on which child a 'Hypo'\/oracle
-- selects, which is why the resolution logic is written once per direction here.
--
-- __Cases (exhaustive, wildcard-free over 'HarnessF', invariant 1).__ A new
-- alphabet constructor must break this too:
--
-- * __'Halt'__: emit the node, then stop — no successor.
-- * __'Render' q k__: emit the node, follow @k (guessOracle h q)@.
-- * __'Perform' c k__: emit the node, follow @k (guessWorld h c)@.
--
-- __Gotcha — fuel counts nodes.__ @go 0@ returns @[]@, so a fuel of @n@ yields at
-- most @n@ nodes; the 'Halt' node itself is included when reached within budget.
takeWalk :: Hypo -> Int -> Cofree HarnessF Ctx -> [Cofree HarnessF Ctx]
takeWalk h fuel = go fuel
  where
    go 0 _ = []
    go n w@(_ :< f) = w : case f of
      Halt _      -> []
      Render q k  -> go (n - 1) (k (guessOracle h q))
      Perform c k -> go (n - 1) (k (guessWorld h c))
