# Shared treefmt base: Nix, markdown, YAML, JSON and TOML.
# Import flakeModules.tooling; extend perSystem.treefmt for consumer languages.
_:
let
  # Closed over, not read from the importing flake: consumers get the linter
  # without declaring an input for it.
  toolingModule =
    { inputs, ... }:
    {
      imports = [ inputs.treefmt-nix.flakeModule ];

      perSystem = _: {
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
          };
        };
      };
    };
in
{
  flake.flakeModules.tooling = toolingModule;

  imports = [ toolingModule ];
}
