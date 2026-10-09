# Podman metrics for the host-local telemetry contract. Selection is
# enablement: the aspect composes Podman's rootful local engine dependency,
# the remote-mode exporter and a loopback scrape registration; this aspect
# names no backend — it registers a local source, and the consumer's selected
# implementation carries it to whatever metrics destination it declares.
#
# It imports the reusable contract fragment (lib/telemetry-contract.nix) so the
# registration is valid without a metrics realization. It remains dormant until
# the host composes a scraper; publishing a source never starts its consumer.
#
# The vendored exporter is built with the `remote` tag and talks to the local
# Podman REST API at `unix:///run/podman/podman.sock`. This aspect imports the
# existing `podman` aspect, which enables rootful Podman and its system socket;
# there is no remote-engine option or rootless user-service inference. The
# daemon socket grants engine-control authority, not read-only metrics access.
# The exporter uses the socket's `podman` group with DynamicUser — a socket
# access boundary requiring the same trust as rootful Podman. No arbitrary
# container labels are copied by default; enabling `--collector.store_labels`
# in `services.podmanExporter.extraFlags` opts into that policy and should name
# only bounded, non-content-bearing labels.
#
# The upstream implementation is temporarily vendored until the fleet's pinned
# nixpkgs carries the merged PR #507097 implementation; the public aspect and
# scrape job (`podman`) remain stable across that replacement.
{ config, ... }:
let
  podman = config.flake.modules.nixos.podman;
in
{
  flake.modules.nixos.podman-exporter =
    { config, lib, ... }:
    let
      cfg = config.services.podmanExporter;
    in
    {
      imports = [
        podman
        ../../lib/telemetry-contract.nix
        ../../lib/notify-contract.nix
        ../../lib/podman-exporter.nix
      ];

      config = {
        services.podmanExporter = {
          port = lib.mkDefault 9156;
          listenAddress = lib.mkDefault "127.0.0.1";
        };

        services.telemetry.scrape.podman = {
          target = "127.0.0.1";
          inherit (cfg) port;
          labels.instance = lib.mkDefault "${config.networking.hostName}:${toString cfg.port}";
        };

        services.notify.events.prometheus-podman-exporter.failure = { };
      };
    };
}
