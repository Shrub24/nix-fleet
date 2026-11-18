{ inputs, ... }:
{
  imports = [ inputs.flake-parts.flakeModules.partitions ];

  partitionedAttrs = {
    checks = "ci";
    herculesCI = "ci";
  };

  partitions.ci = {
    extraInputsFlake = ../../ci;
    module =
      { inputs, ... }:
      {
        imports = [ inputs.self.flakeModules.ci ];

        ci = {
          instance = inputs.ci-instance.lib.instance;
          retention.generations = 3;
          updates.when = {
            minute = 43;
            hour = [ 4 ];
          };
        };
      };
  };
}
