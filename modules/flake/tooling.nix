# Published tooling flakeModule — the base formatting layer for every
# repository that selects it (`imports = [ inputs.nix-fleet.flakeModules.tooling ];`).
#
# Fixed by the base: projectRootFile, the Nix trio (nixfmt + statix + deadnix,
# priorities pinned — all three claim `*.nix`; unpinned, `nix fmt` does not
# converge), baseline excludes, and prettier for markdown/YAML/JSON.
# Consumer extension: treefmt settings merge — consumers add languages
# (programs.*) and extra excludes via the same `perSystem.treefmt` options;
# list options concatenate. A repo whose languages are exactly the base set
# needs no extension.
#
# The module is bound in a `let` and used twice: flake.flakeModules entries
# are published only, never auto-applied to the defining flake.
_:
let
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
