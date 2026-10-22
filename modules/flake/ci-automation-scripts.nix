# Bundled preparation and promotion-to-retention handoff.
{
  perSystem =
    { pkgs, ... }:
    {
      checks.ci-automation-scripts =
        pkgs.runCommand "ci-automation-scripts-check"
          {
            nativeBuildInputs = [
              (pkgs.python3.withPackages (ps: [ ps.pyyaml ]))
              pkgs.bash
              pkgs.gitMinimal
              pkgs.jq
            ];
          }
          ''
            cp -r ${../../.github} ./.github
            python3 ${../../tests/ci/automation_scripts_check.py}
            touch $out
          '';
    };
}
