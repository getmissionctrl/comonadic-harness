# comonadic-harness/default.nix
{ pkgs }:
let
  hp = pkgs.haskellPackages.override {
    overrides = self: super: {
      aeson-jsonpath = pkgs.haskell.lib.doJailbreak (self.callHackageDirect {
        pkg = "aeson-jsonpath";
        ver = "0.3.0.2";
        sha256 = "sha256-q5gt4HOyCtigFlUI/g0g8SV8ltX3MtUxKGrVIdkNxRk=";
      } {});
    };
  };
in
hp.callCabal2nix "comonadic-harness" ./. { }
