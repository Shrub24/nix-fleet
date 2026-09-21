# Notification dispatch capability (Telegram + ntfy) realizing native systemd
# event notifications. Selection is enablement. The implementation packages are
# owned here (overridable); chatId, topics, and other dispatch policy are
# consumer bindings. Secrets follow the two-step sops bootstrap.
#
# Registration contract: services.notify.events.<unit>.{failure,success}
# (see notify/_notify-events.nix). The aspect validates each registered unit against
# the systemd service set, renders /etc/notify/events.json, and attaches the
# native OnFailure=/OnSuccess= hooks — additive (mkBefore), never replacing
# hooks an owner already set. Handlers use Wants= + After= on the daemon and
# fail best-effort: a broken notification pipeline must not affect the health
# semantics of the observed unit, and cannot recurse onto itself.
{ withSystem, ... }:
{
  flake.modules.nixos.notify =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      secretHelpers = import ../../lib/secrets.nix { inherit lib; };

      packages = withSystem pkgs.stdenv.hostPlatform.system (
        { config, ... }:
        {
          inherit (config.packages) notify;
        }
      );

      cfg = config.services.notify;

      telegramTokenReady = cfg.secretFiles.host != null && builtins.pathExists cfg.secretFiles.host;
      ntfyTokenReady =
        cfg.secretFiles.hostSystem != null && builtins.pathExists cfg.secretFiles.hostSystem;

      notifyConfig = {
        telegram = {
          token_file = cfg.telegram.tokenFile;
          chat_id = cfg.telegram.chatId;
          topics = cfg.telegram.topics;
        };
        ntfy = lib.optionalAttrs (cfg.ntfy.enable && cfg.ntfy.serverUrl != "") {
          server_url = cfg.ntfy.serverUrl;
          topics = cfg.ntfy.topics;
          token_file = cfg.ntfy.tokenFile;
        };
      };

      # Registered units with at least one declared event.
      registeredUnits = lib.filterAttrs (_unit: ev: ev.failure != null || ev.success != null) cfg.events;

      # Fail-closed: a registration may only name a unit with a real service
      # implementation. The predicate reads only implementation attributes and
      # never the hooks this aspect attaches, so a phantom registration whose
      # only trace is the hook itself is rejected.
      unitImplemented =
        unit:
        let
          svc = config.systemd.services.${unit} or null;
        in
        svc != null && ((svc.serviceConfig.ExecStart or null) != null || (svc.script or "") != "");

      # One event's entry in the policy map: defaults resolved here, so the
      # handler never needs fallback logic and the JSON only carries declared
      # events.
      eventEntry =
        _event: policy:
        {
          inherit (policy) severity;
          inherit (policy) journalLines;
          inherit (policy) context;
        }
        // lib.optionalAttrs (policy.topic != null) { inherit (policy) topic; }
        // lib.optionalAttrs (policy.title != null) { inherit (policy) title; };

      # Policy map consumed by unit-notify, keyed by $MONITOR_UNIT.
      eventsJson = lib.mapAttrs (
        _unit: ev:
        lib.optionalAttrs (ev.failure != null) { failure = eventEntry "failure" ev.failure; }
        // lib.optionalAttrs (ev.success != null) { success = eventEntry "success" ev.success; }
      ) registeredUnits;
    in
    {
      imports = [ ./notify/_notify-events.nix ];

      options.services.notify = {
        port = lib.mkOption {
          type = lib.types.port;
          default = 5555;
          description = "Loopback TCP port for external HTTP callers (webhooks).";
        };

        package = lib.mkOption {
          type = lib.types.package;
          default = packages.notify;
          defaultText = lib.literalExpression "packages.notify";
          description = ''
            Implementation package providing `bin/notify` (CLI) and
            `bin/unit-notify` (systemd event handler) on one shared dispatch
            library. Owned by this repository; override only to swap it.
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
            default = "/run/secrets/notify/telegram_bot_token";
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
            default = "/run/secrets/notify/ntfy_token";
            description = "Runtime path of the ntfy token; materialized from `secretFiles.hostSystem`.";
          };
        };
      };

      config = lib.mkMerge [
        {
          assertions = [
            {
              assertion = cfg.telegram.chatId != null && cfg.telegram.chatId != "";
              message = "notify: services.notify.telegram.chatId must be set to the Telegram supergroup chat ID.";
            }
            {
              assertion = cfg.telegram.topics != { };
              message = "notify: services.notify.telegram.topics must be configured with at least one tier.";
            }
          ]
          ++ lib.optional (cfg.ntfy.enable && cfg.ntfy.serverUrl == "") {
            assertion = false;
            message = "notify: services.notify.ntfy.serverUrl must be set when ntfy is enabled.";
          }
          ++ lib.mapAttrsToList (unit: ev: {
            assertion = ev.fromPackage || unitImplemented unit;
            message = "notify: events.${unit} is registered but has no systemd service implementation (serviceConfig.ExecStart or script; set fromPackage for units provided by systemd.packages); hooks attached by this aspect do not count. Register from the capability that owns the unit.";
          }) registeredUnits;

          environment.etc."notify/config.json" = {
            mode = "0444";
            text = builtins.toJSON notifyConfig;
          };

          environment.etc."notify/events.json" = lib.mkIf (eventsJson != { }) {
            mode = "0444";
            source = pkgs.writers.writeJSON "events.json" eventsJson;
          };

          environment.systemPackages = [
            cfg.package
            pkgs.apprise
          ];

          users.users.notify = {
            isSystemUser = true;
            group = "notify";
            extraGroups = [ "systemd-journal" ];
            description = "Notification daemon";
          };
          # Socket access model: callers join this group from their own module
          # (users.users.<name>.extraGroups += [ "notify" ]). Groups cannot
          # nest, so membership is expressed per caller user, not here.
          users.groups.notify = { };

          systemd.services.notify = {
            description = "Notification dispatch daemon";
            after = [ "sops-nix.service" ];
            wants = [ "sops-nix.service" ];
            wantedBy = [ "multi-user.target" ];

            environment.NOTIFY_SOCKET_PATH = "/run/notify/notify.sock";

            serviceConfig = {
              Type = "simple";
              ExecStart = "${cfg.package}/bin/notify serve --port ${toString cfg.port} --socket /run/notify/notify.sock";
              Restart = "on-failure";
              RestartSec = "5s";
              User = "notify";
              Group = "notify";
              RuntimeDirectory = "notify";
              RuntimeDirectoryMode = "0750";
              NoNewPrivileges = true;
              PrivateTmp = true;
              ProtectSystem = "strict";
              ProtectHome = true;
              ReadOnlyPaths = [
                "/etc/notify"
                "/run/secrets"
              ];
            };
          };

        }

        (lib.mkIf telegramTokenReady {
          sops.secrets."notify/telegram_bot_token" = {
            sopsFile = cfg.secretFiles.host;
            key = cfg.secretKeys.telegramBotToken;
            path = cfg.telegram.tokenFile;
            owner = "notify";
            group = "notify";
            mode = "0400";
          };
        })

        (lib.mkIf (cfg.ntfy.enable && ntfyTokenReady) {
          sops.secrets."notify/ntfy_token" = {
            sopsFile = cfg.secretFiles.hostSystem;
            key = cfg.secretKeys.ntfyToken;
            path = cfg.ntfy.tokenFile;
            owner = "notify";
            group = "notify";
            mode = "0400";
          };
        })

        # Realization of the registration contract: one generic template
        # handler preserves $MONITOR_* context for every source unit; policy
        # is keyed by $MONITOR_UNIT in /etc/notify/events.json. Hooks attach
        # additively to the owning unit's own definition.
        (lib.mkIf (eventsJson != { }) {
          systemd.services = {
            "notify-event@" = {
              description = "Notification handler for %i";
              serviceConfig = {
                Type = "oneshot";
                ExecStart = "${cfg.package}/bin/unit-notify";
                User = "root";
                Group = "root";
                # Best-effort delivery: a failing handler must not spawn further
                # event notifications or influence the observed unit.
                Restart = "no";
              };
              environment.NOTIFY_SOCKET_PATH = "/run/notify/notify.sock";
              # The handler targets the daemon socket; ordering keeps the
              # daemon up without making the observed unit depend on it.
              after = [ "notify.service" ];
              wants = [ "notify.service" ];
            };
          }
          // lib.mapAttrs' (unit: _ev: {
            name = unit;
            value = {
              onFailure = lib.mkBefore [ "notify-event@${unit}.service" ];
              onSuccess = lib.mkBefore (
                lib.optional (cfg.events.${unit}.success != null) "notify-event@${unit}.service"
              );
            };
          }) registeredUnits;
        })
      ];
    };
}
