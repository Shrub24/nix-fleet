{ withSystem, ... }:
{
  flake.modules.nixos.bifrost =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.bifrost;
      json = pkgs.formats.json { };
      plugins = lib.sort (a: b: a.order < b.order) (
        lib.mapAttrsToList (
          name: plugin:
          {
            inherit name;
            inherit (plugin)
              enabled
              placement
              order
              config
              ;
          }
          // lib.optionalAttrs (plugin.path != null) { path = toString plugin.path; }
        ) cfg.plugins
      );
      renderedConfig = cfg.settings // {
        config_store = (cfg.settings.config_store or { }) // {
          enabled = false;
        };
        inherit plugins;
      };
      configFile = json.generate "bifrost-config.json" renderedConfig;
    in
    {
      imports = [ ../notifications/notify/_notify-events.nix ];

      options.services.bifrost = {
        package = lib.mkOption {
          type = lib.types.package;
          default = withSystem pkgs.stdenv.hostPlatform.system ({ config, ... }: config.packages.bifrost);
          description = "Bifrost runtime. Dynamic plugins must be built with this package's mkPlugin.";
        };
        host = lib.mkOption {
          type = lib.types.str;
          default = "127.0.0.1";
          description = "Listener address. The consumer owns remote access and firewall policy.";
        };
        port = lib.mkOption {
          type = lib.types.port;
          default = 8080;
        };
        dataDir = lib.mkOption {
          type = lib.types.str;
          default = "/var/lib/bifrost";
          description = "Managed application directory, containing config.json and runtime state.";
        };
        logLevel = lib.mkOption {
          type = lib.types.enum [
            "debug"
            "info"
            "warn"
            "error"
          ];
          default = "info";
        };
        environment = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
          description = "Non-secret process environment. Use environmentFile for credentials.";
        };
        environmentFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Runtime environment file, usually a consumer-rendered SOPS template. Settings can reference secrets with Bifrost's env.VARIABLE syntax.";
        };
        settings = lib.mkOption {
          type = lib.types.submodule {
            freeformType = json.type;
            options.config_store.enabled = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Must remain false: the module owns startup configuration.";
            };
          };
          default = { };
          description = "Mergeable Bifrost config.json. plugins is owned by plugins.* and the config store must remain disabled. Secret values must not appear here.";
        };
        plugins = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.submodule {
              options = {
                enabled = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                };
                path = lib.mkOption {
                  type = lib.types.nullOr lib.types.path;
                  default = null;
                  description = "Native plugin .so built against package; null selects a built-in plugin.";
                };
                placement = lib.mkOption {
                  type = lib.types.enum [
                    "pre_builtin"
                    "post_builtin"
                    "builtin"
                  ];
                  default = "post_builtin";
                };
                order = lib.mkOption {
                  type = lib.types.int;
                  default = 0;
                  description = "Plugin execution order. Entries render in ascending order, with names breaking ties.";
                };
                config = lib.mkOption {
                  type = lib.types.submodule { freeformType = json.type; };
                  default = { };
                };
              };
            }
          );
          default = { };
          description = "Plugins keyed by upstream plugin name; the sole owner of config.json's plugins list.";
        };
        renderedConfig = lib.mkOption {
          inherit (json) type;
          readOnly = true;
          description = "Effective startup configuration as data.";
        };
        renderedConfigFile = lib.mkOption {
          type = lib.types.path;
          readOnly = true;
          description = "Effective startup configuration in the Nix store; contains no credentials.";
        };
      };

      config = {
        assertions = [
          {
            assertion = !(cfg.settings ? plugins);
            message = "bifrost: settings.plugins is reserved; register plugins through services.bifrost.plugins.";
          }
          {
            assertion = !(cfg.settings.config_store.enabled or false);
            message = "bifrost: config_store.enabled must be false; startup configuration is Nix-owned.";
          }
          {
            assertion =
              lib.hasPrefix "/" cfg.dataDir
              && !(builtins.elem ".." (lib.splitString "/" cfg.dataDir))
              && cfg.dataDir != "/";
            message = "bifrost: dataDir must be an absolute application directory, not / or a traversal path.";
          }
        ];

        services.bifrost = {
          inherit renderedConfig;
          renderedConfigFile = configFile;
        };
        services.notify.events.bifrost.failure = { };
        users.groups.bifrost = { };
        users.users.bifrost = {
          isSystemUser = true;
          group = "bifrost";
        };
        systemd.tmpfiles.rules = [ "d ${cfg.dataDir} 0700 bifrost bifrost - -" ];
        systemd.services.bifrost = {
          description = "Bifrost AI gateway";
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
          unitConfig.RequiresMountsFor = [ cfg.dataDir ];
          inherit (cfg) environment;
          restartTriggers = [ configFile ];
          preStart = ''
            ${pkgs.coreutils}/bin/install -m 0400 ${configFile} ${lib.escapeShellArg "${cfg.dataDir}/config.json"}
          '';
          serviceConfig = {
            Type = "simple";
            User = "bifrost";
            Group = "bifrost";
            WorkingDirectory = cfg.dataDir;
            EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
            ExecStart = lib.escapeShellArgs [
              "${cfg.package}/bin/bifrost-http"
              "-app-dir"
              cfg.dataDir
              "-host"
              cfg.host
              "-port"
              (toString cfg.port)
              "-log-level"
              cfg.logLevel
            ];
            Restart = "on-failure";
            RestartSec = 5;
            UMask = "0077";
            NoNewPrivileges = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            ReadWritePaths = [ cfg.dataDir ];
          };
        };
      };
    };
}
