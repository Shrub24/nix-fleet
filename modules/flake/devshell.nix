# Repository-local operator shell; the formatter itself is the published
# flakeModules.tooling.
{ inputs, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    {
      devShells.default = pkgs.mkShell {
        packages = with pkgs; [
          nixd
          nil
          statix
          deadnix
          nixfmt
          treefmt
          nix-output-monitor
          inputs.nixpkgs-jactionlint.legacyPackages.${system}.jactionlint
          (python3.withPackages (pythonPackages: [ pythonPackages.pyyaml ]))
        ];
        NIX_CONFIG = "experimental-features = nix-command flakes";
      };
    };
}
