# SMART disk metrics for the host-local telemetry contract. Selection is
# enablement: the aspect composes nixpkgs' own SMART module onto a loopback
# bind and publishes its own scrape registration, so the implementation's
# target cannot drift from where the exporter listens. This aspect names no
# backend — it registers a local source; the consumer's selected
# implementation carries it to whatever metrics destination it declares.
#
# It imports the reusable contract fragment (lib/telemetry-contract.nix) so the
# registration is valid without a metrics realization. It remains dormant until
# the host composes a scraper; publishing a source never starts its consumer.
#
# Device scope, exclusions and polling interval stay nixpkgs'
# (`services.prometheus.exporters.smartctl`): the consumer owns which disks are
# worth querying and how often. The registration reads that module's own
# `port`, so a consumer overriding it moves the listener and the scrape target
# together.
#
# Privilege note: nixpkgs' module gives this exporter raw-device access
# (CAP_SYS_RAWIO/CAP_SYS_ADMIN, `disk` and `smartctl-exporter-access`
# supplementary groups, udev ACL rules for NVMe). That is the mechanism disk
# telemetry requires, and it is why this aspect is opt-in per host rather than
# part of a baseline: selecting it grants that access.
_: {
  flake.modules.nixos.smartctl-exporter =
    { config, lib, ... }:
    let
      native = config.services.prometheus.exporters.smartctl;
    in
    {
      imports = [
        ../../lib/telemetry-contract.nix
        ../../lib/notify-contract.nix
      ];

      config = {
        services.prometheus.exporters.smartctl = {
          enable = true;
          # Loopback only: the collector runs on this host and dials it there.
          # `openFirewall` keeps nixpkgs' false default — the port is not a
          # remote surface, and a remote scrape would be a different design.
          listenAddress = "127.0.0.1";
        };

        services.telemetry.scrape.smartctl = {
          target = "127.0.0.1";
          inherit (native) port;
          labels.instance = lib.mkDefault "${config.networking.hostName}:${toString native.port}";
        };

        # This aspect owns the unit, so it registers the failure. The key is
        # nixpkgs' unit name, not the aspect's — the contract hooks units.
        services.notify.events.prometheus-smartctl-exporter.failure = { };
      };
    };
}
