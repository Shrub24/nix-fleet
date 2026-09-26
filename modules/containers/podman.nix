# Podman baseline: the container runtime hygiene both consumers duplicated.
# Owns the runtime's host-independent policy surface — storage prune, the
# start-limit guard that keeps a crash-looping container unit from restarting
# forever, and the failure registrations those units imply. Container
# definitions and per-host runtime choices (dockerCompat, default-network DNS)
# stay consumer-side.
{ lib, ... }:
{
  flake.modules.nixos.podman =
    { config, ... }:
    let
      cfg = config.services.podman-baseline;

      containers = config.virtualisation.oci-containers.containers;
    in
    {
      # Registration is unconditional in the class: the shared fragment declares
      # the namespace, and the notify aspect realizes it only when co-selected.
      imports = [ ../notifications/notify/_notify-events.nix ];

      options.services.podman-baseline = {
        enable = lib.mkEnableOption "the shared Podman baseline (storage prune + container-unit guard)";

        autoPrune = {
          dates = lib.mkOption {
            type = lib.types.str;
            default = "weekly";
            description = "systemd calendar expression for the storage prune timer.";
          };

          flags = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [
              "--all"
              "--force"
            ];
            description = ''
              Flags for `podman system prune`. `--volumes` is deliberately not
              defaulted: it reclaims volumes whose container was removed, which
              is data loss wherever state lives in a named volume. Hosts that
              want it add it explicitly, having checked their bind mounts.
            '';
          };
        };

        startLimit = {
          intervalSec = lib.mkOption {
            type = lib.types.int;
            default = 300;
            description = "Start-limit window for oci-container units.";
          };

          burst = lib.mkOption {
            type = lib.types.int;
            default = 5;
            description = ''
              Starts allowed per window. nixpkgs gives container units
              Restart = "on-failure" and TimeoutStartSec = 0, so a container in
              a multi-second crash cycle never trips systemd's default limit
              (5/10s) and never reaches `failed` — where a failure
              notification, and an operator, can see it.
            '';
          };
        };

        notifyContainerFailures = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Register a failure event for every oci-container unit. Off by
            default: containers are consumer-declared, so per-container policy
            (an added success event, a severity override) stays the owner's
            call. Inert unless the notify aspect is co-selected.
          '';
        };
      };

      config = lib.mkIf cfg.enable {
        virtualisation.podman = {
          enable = lib.mkDefault true;

          autoPrune = {
            enable = lib.mkDefault true;
            inherit (cfg.autoPrune) dates flags;
          };
        };

        # nixpkgs names the unit from `serviceName` (default `${backend}-${name}`),
        # so mapping over containers instead of composing "podman-${name}"
        # covers renamed units too. Additive unit config — no ExecStart fight.
        systemd.services = lib.mapAttrs' (
          _: container:
          lib.nameValuePair container.serviceName {
            startLimitIntervalSec = cfg.startLimit.intervalSec;
            startLimitBurst = cfg.startLimit.burst;
          }
        ) containers;

        # The aspect owns the prune configuration, so it owns the failure
        # event: nixpkgs defines the unit and timer, the flags and cadence are
        # ours. Registration is inert without the notify aspect co-selected.
        # Container units are consumer-declared, so their failure events are
        # opt-in; per-container policy (success, severity) still merges on top.
        services.notify.events = {
          "podman-prune".failure = { };
        }
        // lib.optionalAttrs cfg.notifyContainerFailures (
          lib.genAttrs (lib.mapAttrsToList (_: container: container.serviceName) containers) (_: {
            failure = { };
          })
        );
      };
    };
}
