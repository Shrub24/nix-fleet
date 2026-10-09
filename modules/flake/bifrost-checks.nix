{ config, lib, ... }:
let
  aspect = config.flake.modules.nixos.bifrost;
in
{
  perSystem =
    {
      config,
      pkgs,
      system,
      ...
    }:
    let
      feeds = {
        pricing_url = "file://${
          pkgs.writeText "bifrost-pricing.json" (
            builtins.toJSON {
              gpt-4o-mini = {
                provider = "openai";
                mode = "chat";
                input_cost_per_token = 0.00000015;
                output_cost_per_token = 0.0000006;
              };
            }
          )
        }";
        model_parameters_url = "file://${
          pkgs.writeText "bifrost-model-parameters.json" (
            builtins.toJSON {
              gpt-4o-mini.supports_reasoning = false;
            }
          )
        }";
        mcp_library_url = "file://${pkgs.writeText "bifrost-mcp-library.json" ''{"servers":[]}''}";
      };
      evaluate =
        extra:
        lib.nixosSystem {
          inherit system;
          modules = [
            aspect
            {
              system.stateVersion = "25.11";
              boot.loader.grub.enable = false;
              fileSystems."/" = {
                device = "nodev";
                fsType = "tmpfs";
              };
            }
            extra
          ];
        };
      evaluated = evaluate {
        services.bifrost = {
          dataDir = "/tmp/bifrost-module-check";
          environment.FIXTURE_PUBLIC_VALUE = "public";
          environmentFile = "/run/secrets/bifrost.environment";
          settings.framework.pricing = feeds;
          settings.governance.routing_rules = [
            {
              id = "fixture-cel";
              name = "Fixture CEL routing";
              enabled = true;
              cel_expression = "true";
              targets = [ { weight = 1; } ];
            }
          ];
          plugins.governance = { };
          plugins.voyage-normalizer.path = "${config.packages.bifrost-voyage-plugin}/lib/bifrost/voyage.so";
        };
      };
      cfg = evaluated.config.services.bifrost;
      unit = evaluated.config.systemd.services.bifrost;
      failures =
        extra: map (a: a.message) (builtins.filter (a: !a.assertion) (evaluate extra).config.assertions);
      valid = lib.asserts.checkAssertWarn evaluated.config.assertions evaluated.config.warnings true;
      lifecycle =
        unit.serviceConfig.User == "bifrost"
        && unit.serviceConfig.Group == "bifrost"
        && unit.serviceConfig.EnvironmentFile == [ "/run/secrets/bifrost.environment" ]
        && unit.serviceConfig.ReadWritePaths == [ cfg.dataDir ]
        && unit.environment.FIXTURE_PUBLIC_VALUE == "public"
        && unit.restartTriggers == [ cfg.renderedConfigFile ]
        && builtins.elem "d ${cfg.dataDir} 0700 bifrost bifrost - -" evaluated.config.systemd.tmpfiles.rules
        && evaluated.config.services.notify.events.bifrost.failure != null
        && cfg.host == "127.0.0.1"
        && cfg.renderedConfig.config_store.enabled
        && cfg.renderedConfig.source_of_truth == "config.json"
        &&
          (lib.findFirst (plugin: plugin.name == "voyage-normalizer") null cfg.renderedConfig.plugins).path
          == "${config.packages.bifrost-voyage-plugin}/lib/bifrost/voyage.so";
      mutation =
        builtins.elem "bifrost: source_of_truth must be config.json; startup configuration is Nix-owned."
          (failures {
            services.bifrost.settings.source_of_truth = "split";
          })
        &&
          builtins.elem
            "bifrost: settings.plugins is reserved; register plugins through services.bifrost.plugins."
            (failures {
              services.bifrost.settings.plugins = [ ];
            });
      launch = pkgs.writeText "bifrost-module-launch.json" (
        builtins.toJSON {
          inherit (cfg) dataDir;
          inherit (unit) preStart;
          command = unit.serviceConfig.ExecStart;
          configFile = cfg.renderedConfigFile;
        }
      );
    in
    {
      # The module's own contract: the unit it renders, the configuration
      # authority it declares, the two option shapes it refuses by name and the
      # failure it registers. Its own check, so a module regression names itself
      # instead of surfacing as a runtime failure.
      checks.bifrost-module =
        assert valid && lifecycle && mutation;
        pkgs.runCommand "bifrost-module-check" { } "touch $out";

      # The live two-cycle authority test: the generated startup path restores
      # the Nix-owned document on fresh state and on restart, and the running
      # process never becomes a second source of truth. Owned runtime behaviour,
      # so it runs the shipped command rather than restating it.
      checks.bifrost-module-runtime =
        pkgs.runCommand "bifrost-module-runtime-check"
          {
            nativeBuildInputs = [
              pkgs.python3
              pkgs.bash
            ];
          }
          ''
            PYTHONPATH=${../../tests/bifrost} ${pkgs.python3}/bin/python3 ${../../tests/bifrost/module_check.py} ${launch} $out
          '';
    };
}
