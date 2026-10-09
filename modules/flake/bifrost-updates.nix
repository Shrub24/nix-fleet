_: {
  perSystem =
    { pkgs, ... }:
    {
      # Which packages this repo hands the shared updater is stated by the
      # registration itself; the check owns the release policy, not a second
      # copy of that list.
      packageUpdates.packages = [ "bifrost" ];
      checks.bifrost-update-policy =
        pkgs.runCommand "bifrost-update-policy-check" { nativeBuildInputs = [ pkgs.python3 ]; }
          ''
            python3 ${../../tests/bifrost/update_check.py} ${../../pkgs/bifrost/update.py}
            touch "$out"
          '';
    };
}
