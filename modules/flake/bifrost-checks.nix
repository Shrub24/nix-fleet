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
      # Offline feeds: startup syncs these URLs and aborts without them.
      feed = name: value: "file://${pkgs.writeText "bifrost-${name}.json" (builtins.toJSON value)}";
      feeds = {
        pricing_url = feed "pricing" {
          gpt-4o-mini = {
            provider = "openai";
            mode = "chat";
            input_cost_per_token = 0.00000015;
            output_cost_per_token = 0.0000006;
          };
        };
        model_parameters_url = feed "model-parameters" { gpt-4o-mini.supports_reasoning = false; };
        mcp_library_url = feed "mcp-library" { servers = [ ]; };
      };
      inspect =
        extra:
        (lib.nixosSystem {
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
        }).config;
      dataDir = "/tmp/bifrost-module-check";
      evaluated = inspect {
        services.bifrost = {
          inherit dataDir;
          settings.framework.pricing = feeds;
          # The runtime test reads back the routing rules and the governance plugin.
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
      default = inspect { };
      cfg = evaluated.services.bifrost;
      unit = evaluated.systemd.services.bifrost;
      defaultUnit = default.systemd.services.bifrost;
      # The two lifecycle modes are the claim: dataDir renders a write path, the
      # default arm hands the directory to systemd instead.
      lifecycle =
        unit.serviceConfig.ReadWritePaths == [ cfg.dataDir ]
        && !(unit.serviceConfig ? StateDirectory)
        && builtins.elem "d ${cfg.dataDir} 0700 bifrost bifrost - -" evaluated.systemd.tmpfiles.rules
        && defaultUnit.serviceConfig.StateDirectory == "bifrost"
        && defaultUnit.serviceConfig.StateDirectoryMode == "0700"
        && defaultUnit.serviceConfig.ReadWritePaths == [ ]
        && !(builtins.elem "d /var/lib/bifrost 0700 bifrost bifrost - -" default.systemd.tmpfiles.rules)
        && unit.restartTriggers == [ cfg.renderedConfigFile ]
        && !(builtins.elem "network-online.target" unit.wants)
        && !(builtins.elem "network-online.target" unit.after)
        && evaluated.services.notify.events.bifrost.failure != null
        && cfg.renderedConfig.config_store.enabled
        &&
          (lib.findFirst (plugin: plugin.name == "voyage-normalizer") null cfg.renderedConfig.plugins).path
          == "${config.packages.bifrost-voyage-plugin}/lib/bifrost/voyage.so";
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
      # The two lifecycle modes and the config authority.
      checks.bifrost-module =
        assert lifecycle;
        pkgs.runCommand "bifrost-module-check" { } "touch $out";

      # The live two-cycle authority test: runs the shipped startup path.
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
