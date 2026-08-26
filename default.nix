# comonadic-harness/default.nix
{ pkgs }:
pkgs.haskellPackages.callCabal2nix "comonadic-harness" ./. { }
