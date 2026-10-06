_: {
  perSystem =
    { config, pkgs, ... }:
    {
      packageUpdates.packages = [ "bifrost" ];
      checks.bifrost-update-policy =
        pkgs.runCommand "bifrost-update-policy-check"
          {
            nativeBuildInputs = [ pkgs.python3 ];
            registered = builtins.toJSON config.packageUpdates.packages;
          }
          ''
            test "$registered" = '["bifrost"]' || {
              echo "package-updates: expected Bifrost as the sole initial owner"
              exit 1
            }
            python3 ${../../tests/bifrost/update_check.py} ${../../pkgs/bifrost/update.py}
            touch "$out"
          '';
    };
}
