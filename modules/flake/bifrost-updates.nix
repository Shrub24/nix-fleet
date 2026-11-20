_: {
  ci.updates.packages.bifrost = { };

  perSystem =
    { pkgs, ... }:
    {
      # The check owns the release policy, not a second copy of the registration.
      checks.bifrost-update-policy =
        pkgs.runCommand "bifrost-update-policy-check" { nativeBuildInputs = [ pkgs.python3 ]; }
          ''
            python3 ${../../tests/bifrost/update_check.py} ${../../pkgs/bifrost/update.py}
            touch "$out"
          '';
    };
}
