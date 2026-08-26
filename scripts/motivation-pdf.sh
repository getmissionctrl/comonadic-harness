#!/usr/bin/env bash
# Render the standalone Motivation essay (docs/motivation.md) to a typeset PDF.
# Motivation is deliberately NOT a Haskell module — it is prose with illustrative
# snippets, so it is a Markdown source rendered via pandoc + a LaTeX engine
# (tectonic, which is self-contained). Run from anywhere in the repo.
set -euo pipefail
cd "$(dirname "$0")/.."

nix shell nixpkgs#pandoc nixpkgs#tectonic -c \
  pandoc docs/motivation.md -o docs/motivation.pdf \
    --pdf-engine=tectonic \
    --highlight-style=tango \
    -V geometry:margin=1in \
    -V colorlinks=true -V linkcolor=blue -V urlcolor=blue

echo "wrote docs/motivation.pdf"
