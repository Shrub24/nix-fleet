# Repository-local operator shell; the formatter itself is the published
# flakeModules.tooling.
_: {
  perSystem =
    { pkgs, ... }:
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
          (callPackage ../../pkgs/jactionlint { })
          (python3.withPackages (pythonPackages: [ pythonPackages.pyyaml ]))
        ];
        NIX_CONFIG = "experimental-features = nix-command flakes";
      };
    };
}
