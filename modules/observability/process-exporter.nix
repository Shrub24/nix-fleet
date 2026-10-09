# Process metrics for the host-local telemetry contract. Selection is
# enablement: the aspect composes nixpkgs' own process-exporter module onto a
# loopback bind and publishes its own scrape registration, so the
# implementation's target cannot drift from where the exporter listens. This
# aspect names no backend — it registers a local source; the consumer's
# selected implementation carries it to whatever metrics destination it
# declares.
#
# It imports the reusable contract fragment (lib/telemetry-contract.nix) so the
# registration is valid without a metrics realization. It remains dormant until
# the host composes a scraper; publishing a source never starts its consumer.
#
# Selectors stay nixpkgs' `services.prometheus.exporters.process.settings`
# (process_names, threads, and anything else process-exporter's config
# accepts) — the consumer owns what is worth monitoring and how it is named.
# There is deliberately no catch-all default: an exporter pointed at every
# process produces high-cardinality series whose names churn with every
# deployment, so an empty selector list fails closed by name instead.
_: {
  flake.modules.nixos.process-exporter =
    { config, lib, ... }:
    let
      native = config.services.prometheus.exporters.process;
    in
    {
      imports = [ ../../lib/telemetry-contract.nix ];

      config = {
        services.prometheus.exporters.process = {
          enable = true;
          # Loopback only: the collector runs on this host and dials it there.
          # `openFirewall` keeps nixpkgs' false default — the port is not a
          # remote surface, and a remote scrape would be a different design.
          listenAddress = "127.0.0.1";
        };

        services.telemetry.scrape.process = {
          target = "127.0.0.1";
          inherit (native) port;
          labels.instance = lib.mkDefault "${config.networking.hostName}:${toString native.port}";
        };

        assertions = [
          {
            assertion = native.settings.process_names != [ ];
            message = "process-exporter: services.prometheus.exporters.process.settings.process_names is empty. process-exporter has no catch-all mode that is safe here — monitoring every process produces high-cardinality series whose names churn with every deployment. Name the processes this host runs (stable names, matched by comm/exe or a bounded cmdline regex), or drop the aspect.";
          }
        ];
      };
    };
}
