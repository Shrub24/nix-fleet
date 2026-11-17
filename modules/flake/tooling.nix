# Shared treefmt base: Nix, markdown, YAML, JSON, TOML and GitHub Actions.
# Import flakeModules.tooling; extend perSystem.treefmt for consumer languages.
{ inputs, ... }:
let
  # Closed over, not read from the importing flake: consumers get the linter
  # without declaring an input for it.
  fleetInputs = inputs;
  toolingModule =
    { inputs, ... }:
    {
      imports = [ inputs.treefmt-nix.flakeModule ];

      perSystem = { system, ... }: {
        treefmt = {
          projectRootFile = "flake.nix";

          settings.global.excludes = [
            ".jj/**"
            ".pi/**"
            "result"
            "result-*"
            "flake.lock"
          ];

          programs = {
            nixfmt.enable = true;
            statix.enable = true;
            deadnix.enable = true;
            prettier.enable = true;
            prettier.includes = [
              "*.md"
              "*.yaml"
              "*.yml"
              "*.json"
            ];
            taplo.enable = true;
          };

          settings.formatter = {
            deadnix.priority = 1;
            statix.priority = 2;
            nixfmt.priority = 3;
            jactionlint = {
              command = "${fleetInputs.nixpkgs-jactionlint.legacyPackages.${system}.jactionlint}/bin/jactionlint";
              options = [
                "--profile"
                "correctness"
              ];
              includes = [
                ".github/workflows/*.yml"
                ".github/actions/**/action.yml"
              ];
            };
          };
        };
      };
    };
in
{
  flake.flakeModules.tooling = toolingModule;

  imports = [ toolingModule ];
}
