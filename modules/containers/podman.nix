# Podman baseline: selection is enablement. Contributes fleet defaults onto
# the platform's own options — no bespoke namespace, so consumer overrides read
# as upstream config (`virtualisation.podman.autoPrune.flags = [ ... ]`).
# Container definitions and per-host runtime choices (dockerCompat,
# default-network DNS) stay consumer-side.
{ lib, ... }:
{
  flake.modules.nixos.podman =
    { config, ... }:
    {
      # Registration is unconditional in the class: the shared fragment declares
      # the namespace, and the notify aspect realizes it only when co-selected.
      imports = [ ../notifications/notify/_notify-events.nix ];

      config = {
        virtualisation.podman = {
          # Real for hosts that use podman without declarative containers
          # (nixpkgs implies it from oci-containers when containers exist).
          enable = lib.mkDefault true;

          autoPrune = {
            enable = lib.mkDefault true;

            # Cadence is nixpkgs' own default (weekly). --volumes is
            # deliberately absent: it reclaims volumes whose container was
            # removed — data loss wherever state lives in a named volume, so
            # hosts add it explicitly after checking their bind mounts.
            # `flags` is a list option, so a consumer's own list APPENDS
            # (mkForce replaces).
            flags = lib.mkDefault [
              "--all"
              "--force"
            ];
          };
        };

        # nixpkgs gives container units Restart = "on-failure" with
        # TimeoutStartSec = 0, so a container in a multi-second crash cycle
        # never trips systemd's default limit (5/10s) and never reaches
        # `failed` — where a failure notification, and an operator, can see it.
        # Keyed on each container's serviceName: renamed units are covered too.
        # mkDefault, so a per-unit override still wins.
        systemd.services = lib.mapAttrs' (
          _: container:
          lib.nameValuePair container.serviceName {
            startLimitIntervalSec = lib.mkDefault 300;
            startLimitBurst = lib.mkDefault 5;
          }
        ) config.virtualisation.oci-containers.containers;

        # The aspect owns the prune configuration, so it owns the failure
        # event: nixpkgs defines the unit and timer, the flags are ours. Inert
        # without the notify aspect co-selected. Container units stay the
        # consumer's to register — they are consumer-declared.
        services.notify.events."podman-prune".failure = { };
      };
    };
}
