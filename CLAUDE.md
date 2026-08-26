# Working agreement

Read `BRIEF.md` before touching anything. `TASKS.md` is ordered; work it in
order. `reference/` is read-only source material, not the codebase.

## Invariants

These are not style preferences. Breaking one means the design has no value.

1. **The alphabet is closed.** No `HarnessF` constructor is added without a
   corresponding case in `run`, in `probe`, and in the law tests. No wildcard
   matches in those three functions. `-Wincomplete-patterns` must fire when a
   constructor is added; if it does not, someone has added a wildcard.
2. **`run` never reads the annotation.** Execution consumes the shape; analysis
   consumes the annotation. If a field of `Ctx` starts influencing execution,
   it belongs in `S` and in `step`.
3. **`Cofree` is a denotation, not a runtime representation.** The
   implementation carries `S` and the coalgebra. Do not serialise the tree, do
   not cache it, do not pass it to the provider.
4. **Evolution lives outside the functor.** `HarnessF` must not mention `S`.
   If you want `Evolve (S -> HarnessF S)`, read §7 and the agents-exe comment
   about the joining function first.
5. **Transient failure never reaches the coalgebra.** Retries, backoff, and
   connection errors are `Env` decorators. Only `Overflow` and terminal decode
   failures are `Refusal`.

## Evidence discipline

- **One interpretation per alphabet.** If two functions both `case` over
  `HarnessF`, they will drift, and the law that they agree is the thing this
  design is for. Factor through `interp` (§16.1).
- **Write the law before the code that satisfies it.** The three that matter
  are listed at the end of §16.
- **Generators go through public transitions, never record construction.**
  Hand-written `S` values can be unreachable, and a property checked on an
  unreachable state measures nothing (§16.7).
- Every experiment gets a baseline null model. A number without one is not a
  result.
- A property checked at one state proves nothing. This bit us already: the
  first `respectsBehaviour` example returned `True` by coincidence. Quantify.
- Failures are designed results. If `E1` shows a high compaction defect rate,
  that is the finding, not a bug to hide.
- Record what you verified empirically versus what you assumed. Ollama's
  overflow behaviour in particular (§12) must be tested, with the version
  number written into `docs/ollama-notes.md`.

## Provenance tagging

Carry the brief's convention into new documents and non-obvious comments:

- `[established]` — proved, cited, or demonstrated by running code here
- `[design]` — a choice made, defensible but not forced
- `[speculative]` — plausible, untested, may be wrong
- `[unbuilt]` — named, not implemented

## Vocabulary

"Polynomial", "coalgebra homomorphism", and "bisimilar" are used in the brief
because there are corresponding definitions in the code. If a refactor removes
the referent, delete the word rather than keeping it for flavour. The same
applies to anything new you introduce.

## Code

- British spelling in prose and comments. Identifiers follow whatever the
  library ecosystem uses.
- `-Wall -Wcompat -Wincomplete-uni-patterns -Wredundant-constraints`, clean.
- Everything derives `Generic`. Optics come from `Optics.Generic` off the back
  of it. **No Template Haskell anywhere in this project**, so no `optics-th`.
- Prefer optic composition over record-update syntax in the coalgebra. `step`
  should read as a state transition, not a pile of field updates.
- Haddock on every exported type and function, saying *why* it exists rather
  than restating the signature.

## When you are stuck

Do not invent structure to route around a problem. The three places this design
is known to be under-powered are D1, D2, and D3 in §10. If you hit something
that is not one of those, it is more likely that `S` is missing a field than
that the alphabet needs a new constructor.
