#!/usr/bin/env bash
# Render the literate Tutorial (src/Harness/Tutorial.lhs) to a typeset PDF.
# The .lhs is a real library module: its `>` code compiles in the build, so the
# examples are guaranteed correct. Here we treat it as literate Markdown
# (pandoc's markdown+lhs reader) and typeset it via a LaTeX engine (tectonic).
# Run from anywhere in the repo.
set -euo pipefail
cd "$(dirname "$0")/.."

nix shell nixpkgs#pandoc nixpkgs#tectonic -c \
  pandoc src/Harness/Tutorial.lhs -f markdown+lhs -o docs/tutorial.pdf \
    --pdf-engine=tectonic \
    --highlight-style=tango \
    -V geometry:margin=1in \
    -V colorlinks=true -V linkcolor=blue -V urlcolor=blue

echo "wrote docs/tutorial.pdf"
