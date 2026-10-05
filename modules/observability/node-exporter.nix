# Node metrics for the host-local telemetry contract. Selection is enablement:
# the aspect owns the exporter, its loopback bind, and its own scrape
# registration, so the implementation's target cannot drift from where the exporter
# listens. This aspect names no backend — it registers a local source; the
# consumer's selected implementation carries it to whatever metrics destination
# it declares.
#
# It imports the reusable contract fragment (lib/telemetry-contract.nix) so the
# registration is valid whether or not the telemetry aspect is co-selected; on a
# host that did not select telemetry the registration fails closed by name (the
# fragment's orphan guard) instead of being silently dropped.
_: {
  flake.modules.nixos.node-exporter =
    { config, lib, ... }:
    let
      cfg = config.services.node-exporter;
    in
    {
      imports = [
        ../../lib/telemetry-contract.nix
        ../notifications/notify/_notify-events.nix
      ];

      options.services.node-exporter = {
        port = lib.mkOption {
          type = lib.types.port;
          default = 9100;
          description = "Port the node exporter listens on and the scrape job targets; one value, so the listener and the registration cannot disagree.";
        };
      };

      config = {
        services.prometheus.exporters.node = {
          enable = true;
          # Loopback only: the collector runs on this host and dials it there.
          # `openFirewall` keeps nixpkgs' false default — the port is not a
          # remote surface, and a remote scrape would be a different design.
          listenAddress = "127.0.0.1";
          inherit (cfg) port;
        };

        services.telemetry.scrape.node = {
          target = "127.0.0.1";
          inherit (cfg) port;
          labels.instance = lib.mkDefault "${config.networking.hostName}:${toString cfg.port}";
        };

        # This aspect owns the unit, so it registers the failure: a stopped
        # exporter is a silent metrics gap until someone asks. The key is
        # nixpkgs' unit name, not the aspect's — the contract hooks units.
        services.notify.events.prometheus-node-exporter.failure = { };
      };
    };
}
