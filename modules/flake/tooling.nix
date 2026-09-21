# Published tooling flakeModule: one treefmt definition for every repository
# that selects it (consumer: `imports = [ inputs.nix-fleet.flakeModules.tooling ];`).
# Priorities are pinned because nixfmt, statix and deadnix all claim `*.nix`;
# unpinned, `nix fmt` does not converge. The module is bound in a `let` and used
# twice: flake.flakeModules entries are published only, never auto-applied here.
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
            mdformat.enable = true;
            mdformat.plugins = ps: [ ps.mdformat-frontmatter ];
            taplo.enable = true;
            yamlfmt.enable = true;
            jsonfmt.enable = true;
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
