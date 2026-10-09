# Adapted Podman exporter helper from NixOS/nixpkgs PR #507097, full head
# b859cd0bd7be2b0ea7d5810dab7c537e9c650a59, source module
# `nixos/modules/services/monitoring/prometheus/exporters/podman.nix`.
#
# The pinned exporter framework statically constructs its option submodule from
# an internal map. Instead of modifying nixpkgs or duplicating that framework,
# this helper contributes the missing local service and its typed fleet option
# surface. The PR package and command contract remain intact; rootful local
# engine access is fixed to nixpkgs' system podman socket.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.podmanExporter;
  args = [
    "--web.listen-address"
    "${cfg.listenAddress}:${toString cfg.port}"
  ]
  ++ cfg.extraFlags;
in
{
  options.services.podmanExporter = {
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../pkgs/prometheus-podman-exporter { };
      description = "Temporary PR #507097 package until the pinned nixpkgs provides it.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 9156;
      description = "Port the exporter listens on and the scrape job targets.";
    };
    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Loopback address the exporter listens on.";
    };
    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "--collector.store_labels"
        "--collector.whitelisted_labels"
        "app,environment"
      ];
      description = "Exporter flags; copying container labels is opt-in and should use a narrow whitelist.";
    };
  };

  config = {
    systemd.services.prometheus-podman-exporter = {
      description = "Prometheus exporter for Podman";
      wantedBy = [ "multi-user.target" ];
      after = [ "podman.socket" ];
      wants = [ "podman.socket" ];
      environment = {
        CONTAINER_HOST = "unix:///run/podman/podman.sock";
        HOME = "/var/lib/prometheus-podman-exporter";
        XDG_CONFIG_HOME = "/var/lib/prometheus-podman-exporter";
      };
      path = [ config.virtualisation.podman.package.helpersBin ];
      serviceConfig = {
        DynamicUser = true;
        StateDirectory = "prometheus-podman-exporter";
        ExecStart = lib.escapeShellArgs ([ (lib.getExe cfg.package) ] ++ args);
        Restart = "on-failure";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        SupplementaryGroups = [ "podman" ];
      };
    };

    assertions = [
      {
        assertion = cfg.listenAddress == "127.0.0.1";
        message = "podman-exporter: services.podmanExporter.listenAddress must remain 127.0.0.1; the fleet exporter is local-only.";
      }
    ];
  };
}
