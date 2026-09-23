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
        # (via `.env`) plus tooling. `ollama` is NOT here — it runs separately.
        devShells.dev = harness.env.overrideAttrs (old: {
          nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
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
