# flake.nix is generated: `nix run .#write-flake` renders it from the input
# declarations in this tree. The dendritic preset declares the flake.modules
# namespace, wires flake-parts and import-tree discovery, and sets the default
# system set, which `systems` below widens to both architectures the fleet
# builds for. Fixture-only inputs (sops-nix, niks3) stay fleet-owned here:
# consumers import their own copies, exactly as they do their own nixpkgs.
{
  inputs,
  ...
}:
{
  imports = [ inputs.flake-file.flakeModules.dendritic ];

  flake-file.description = "Reusable NixOS fleet infrastructure aspects";

  systems = [
    "x86_64-linux"
    "aarch64-linux"
  ];

  flake-file.inputs = {
    flake-file.url = "github:denful/flake-file";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    import-tree.url = "github:denful/import-tree";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    niks3 = {
      url = "github:Mic92/niks3";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        treefmt-nix.follows = "treefmt-nix";
      };
    };
  };
}
