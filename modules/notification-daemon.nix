# Notification dispatch (Telegram + ntfy) and the monitor.units registration
# namespace. Selection is enablement. Package, notifyPackage, chatId, and
# topics are consumer bindings — this repo publishes modules, not policy or
# packages. Secrets follow the two-step sops bootstrap.
_: {
  flake.modules.nixos.notification-daemon =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      secretHelpers = import ../lib/secrets.nix { inherit lib; };

      cfg = config.services.notification-daemon;

      telegramTokenReady = cfg.secretFiles.host != null && builtins.pathExists cfg.secretFiles.host;
      ntfyTokenReady =
        cfg.secretFiles.hostSystem != null && builtins.pathExists cfg.secretFiles.hostSystem;

      daemonReady = cfg.package != null && cfg.notifyPackage != null;

      notifyConfig = {
        token_file = cfg.telegram.tokenFile;
        chat_id = cfg.telegram.chatId;
        topics = cfg.telegram.topics;
        ntfy = lib.optionalAttrs (cfg.ntfy.enable && cfg.ntfy.serverUrl != "") {
          server_url = cfg.ntfy.serverUrl;
          topics = cfg.ntfy.topics;
          token_file = cfg.ntfy.tokenFile;
        };
      };

      # Fail-closed: a monitor contribution may only name a unit with a real
      # service implementation. The predicate reads only implementation
      # attributes (serviceConfig.ExecStart or a non-empty script) and never the
      # hooks this module injects (OnFailure, ExecStartPost, ExecStopPost), so a
      # monitor-created fragment can never satisfy its own assertion.
      monitorUnitImplemented =
        unit:
        let
          svc = config.systemd.services.${unit} or null;
        in
        svc != null && ((svc.serviceConfig.ExecStart or null) != null || (svc.script or "") != "");

      monitorScript = pkgs.writeScriptBin "svc-monitor" ''
        #!${pkgs.python3}/bin/python3
        import json, subprocess, sys, urllib.request

        unit = sys.argv[1] if len(sys.argv) > 1 else sys.exit("Usage: svc-monitor <unit>")
        event = sys.argv[2] if len(sys.argv) > 2 else "onFailure"

        journal = subprocess.run(
            ["journalctl", "-u", unit, "--since", "5 minutes ago", "--no-pager", "-n", "50"],
            capture_output=True, text=True, timeout=15,
        ).stdout or ""

        title = "[%s] monitor: %s" % (event, unit)
        body = journal
        tier = "warning" if event == "onFailure" else "info"
        ntype = event

        payload = json.dumps({"tier": tier, "title": title, "type": ntype, "message": body}).encode()
        req = urllib.request.Request(
            "http://127.0.0.1:${toString cfg.port}/notify",
            data=payload,
            headers={"Content-Type": "application/json"},
        )
        try:
            urllib.request.urlopen(req, timeout=10)
        except urllib.error.HTTPError as e:
            sys.exit("daemon error: %d %s" % (e.code, e.read().decode()))
        except (urllib.error.URLError, OSError) as e:
            sys.exit("daemon connection failed: %s" % e)
      '';
    in
    {
      options.services.notification-daemon = {
        port = lib.mkOption {
          type = lib.types.port;
          default = 5555;
          description = "Port on which the notification daemon listens (127.0.0.1 only).";
        };

        package = lib.mkOption {
          type = lib.types.nullOr lib.types.package;
          default = null;
          description = ''
            Notification daemon implementation providing `bin/notification-daemon`.
            Consumer-supplied: this repository publishes modules only.
          '';
        };

        notifyPackage = lib.mkOption {
          type = lib.types.nullOr lib.types.package;
          default = null;
          description = ''
            Notify CLI implementation providing `bin/notify`. Consumer-supplied:
            this repository publishes modules only.
          '';
        };

        secretFiles = {
          host = secretHelpers.mkSecretFileOption "the Telegram bot token";

          hostSystem = secretHelpers.mkSecretFileOption "the ntfy access token";
        };

        secretKeys = {
          telegramBotToken = lib.mkOption {
            type = lib.types.str;
            default = "telegram_bot_token";
            description = "SOPS key path of the bot token inside `secretFiles.host`.";
          };

          ntfyToken = lib.mkOption {
            type = lib.types.str;
            default = "ntfy_token";
            description = "SOPS key path of the ntfy token inside `secretFiles.hostSystem`.";
          };
        };

        telegram = {
          chatId = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Telegram supergroup chat ID notifications are sent to. Policy data: consumer-supplied.";
          };

          topics = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description = "Mapping of notification tiers to Telegram topic IDs within the supergroup. Policy data: consumer-supplied.";
          };

          tokenFile = lib.mkOption {
            type = lib.types.str;
            default = "/run/secrets/notification-daemon/telegram_bot_token";
            description = "Runtime path of the Telegram bot token; materialized from `secretFiles.host`.";
          };
        };

        ntfy = {
          enable = lib.mkEnableOption "ntfy dispatch alongside Telegram";

          serverUrl = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "ntfy server URL. Required when ntfy is enabled; the origin host typically overrides to loopback.";
          };

          topics = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = {
              system = "system";
              services = "services";
            };
            description = "Semantic ntfy topic names; the tier map's values select among them.";
          };

          tokenFile = lib.mkOption {
            type = lib.types.str;
            default = "/run/secrets/notification-daemon/ntfy_token";
            description = "Runtime path of the ntfy token; materialized from `secretFiles.hostSystem`.";
          };
        };

        monitor = {
          enable = lib.mkEnableOption "systemd service notification monitors";

          units = lib.mkOption {
            type = lib.types.attrsOf (
              lib.types.submodule {
                options = {
                  onFailure = lib.mkOption {
                    type = lib.types.bool;
                    default = false;
                    description = "Activate svc-monitor@<unit>.service when <unit> enters the failed state (OnFailure).";
                  };

                  onStart = lib.mkOption {
                    type = lib.types.bool;
                    default = false;
                    description = "Report each start attempt of <unit> (ExecStartPost).";
                  };

                  onStop = lib.mkOption {
                    type = lib.types.bool;
                    default = false;
                    description = "Report each termination of <unit> (ExecStopPost).";
                  };
                };
              }
            );
            default = { };
            description = ''
              Systemd units to monitor, contributed by the capability that owns
              them. Only the declared lifecycle events are hooked, and every entry
              must name a real service implementation.
            '';
          };
        };
      };

      config = lib.mkMerge [
        {
          assertions = [
            {
              assertion = cfg.package != null;
              message = "notification-daemon: services.notification-daemon.package must be set to the daemon implementation (this repository publishes modules, not packages).";
            }
            {
              assertion = cfg.notifyPackage != null;
              message = "notification-daemon: services.notification-daemon.notifyPackage must be set to the notify CLI implementation (this repository publishes modules, not packages).";
            }
            {
              assertion = cfg.telegram.chatId != null && cfg.telegram.chatId != "";
              message = "notification-daemon: services.notification-daemon.telegram.chatId must be set to the Telegram supergroup chat ID.";
            }
            {
              assertion = cfg.telegram.topics != { };
              message = "notification-daemon: services.notification-daemon.telegram.topics must be configured with at least one tier.";
            }
          ]
          ++ lib.optional (cfg.ntfy.enable && cfg.ntfy.serverUrl == "") {
            assertion = false;
            message = "notification-daemon: services.notification-daemon.ntfy.serverUrl must be set when ntfy is enabled.";
          }
          ++ lib.optionals cfg.monitor.enable (
            lib.mapAttrsToList (unit: _events: {
              assertion = monitorUnitImplemented unit;
              message = "notification-daemon: services.notification-daemon.monitor.units: '${unit}' is contributed for monitoring but has no systemd service implementation (serviceConfig.ExecStart or script); monitor-generated hooks do not count. Contribute monitoring from the capability that owns the unit.";
            }) cfg.monitor.units
          );
        }

        (lib.mkIf daemonReady {
          environment.etc."notification-daemon/config.json" = {
            mode = "0444";
            text = builtins.toJSON notifyConfig;
          };

          environment.systemPackages = [
            cfg.package
            pkgs.apprise
            cfg.notifyPackage
          ]
          ++ lib.optionals cfg.monitor.enable [ monitorScript ];

          systemd.services = {
            notification-daemon = {
              description = "HTTP notification dispatch daemon";
              after = [ "sops-nix.service" ];
              wants = [ "sops-nix.service" ];
              wantedBy = [ "multi-user.target" ];

              serviceConfig = {
                Type = "simple";
                ExecStart = "${cfg.package}/bin/notification-daemon";
                Restart = "on-failure";
                RestartSec = "5s";
                User = "root";
                NoNewPrivileges = true;
                PrivateTmp = true;
                ProtectSystem = "strict";
                ProtectHome = true;
                ReadWritePaths = [ "/run" ];
                ReadOnlyPaths = [
                  "/etc/notification-daemon"
                  "/run/secrets"
                ];
              };
            };
          }
          // lib.optionalAttrs cfg.monitor.enable (
            let
              mon = "svc-monitor@";
            in
            {
              "${mon}" = {
                description = "Notification monitor for %I";
                serviceConfig = {
                  Type = "oneshot";
                  ExecStart = "-${monitorScript}/bin/svc-monitor %I onFailure";
                  User = "root";
                  Group = "root";
                };
              };
            }
            //
              lib.mapAttrs'
                (
                  unit: events:
                  lib.nameValuePair unit (
                    # OnFailure activates svc-monitor@<unit>.service when the unit
                    # enters the failed state; the Exec hooks fire on every run. The
                    # hooks are merged into (never replaced over) whatever the owning
                    # capability already defined for the unit.
                    lib.optionalAttrs events.onFailure {
                      onFailure = lib.mkBefore [ "${mon}${unit}.service" ];
                    }
                    // lib.optionalAttrs (events.onStart || events.onStop) {
                      serviceConfig =
                        lib.optionalAttrs events.onStart {
                          ExecStartPost = lib.mkBefore [
                            "-${monitorScript}/bin/svc-monitor ${unit} onStart"
                          ];
                        }
                        // lib.optionalAttrs events.onStop {
                          ExecStopPost = lib.mkAfter [
                            "-${monitorScript}/bin/svc-monitor ${unit} onSuccess"
                          ];
                        };
                    }
                  )
                )
                (lib.filterAttrs (_: events: events.onFailure || events.onStart || events.onStop) cfg.monitor.units)
          );
        })

        (lib.mkIf telegramTokenReady {
          sops.secrets."notification-daemon/telegram_bot_token" = {
            sopsFile = cfg.secretFiles.host;
            key = cfg.secretKeys.telegramBotToken;
            path = cfg.telegram.tokenFile;
            owner = "root";
            group = "root";
            mode = "0440";
          };
        })

        (lib.mkIf (cfg.ntfy.enable && ntfyTokenReady) {
          sops.secrets."notification-daemon/ntfy_token" = {
            sopsFile = cfg.secretFiles.hostSystem;
            key = cfg.secretKeys.ntfyToken;
            path = cfg.ntfy.tokenFile;
            owner = "root";
            group = "root";
            mode = "0440";
          };
        })
      ];
    };
}
