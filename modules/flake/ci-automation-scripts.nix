# Exercises where candidate.yml, promote-candidate.yml and validate.yml take the
# automation scripts from: the defining revision, never the caller's workspace.
{
  perSystem =
    { pkgs, ... }:
    {
      checks.ci-automation-scripts =
        pkgs.runCommand "ci-automation-scripts-check"
          {
            nativeBuildInputs = [
              (pkgs.python3.withPackages (ps: [ ps.pyyaml ]))
            ];
          }
          ''
            cp -r ${../../.github} ./.github
            python3 ${../../tests/ci/automation_scripts_check.py}
            touch $out
          '';
    };
}
