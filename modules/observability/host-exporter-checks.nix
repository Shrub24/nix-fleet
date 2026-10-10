# Producer-owned checks for host exporter aspects. Each leaf asserts the authored
# join: native listener/selection to scrape registration. nixpkgs owns exporter
# argument semantics and unit privileges; these leaves check fleet composition.
#
# Every leaf here reads option values, static unit settings, or a predicate over
# a rendered service string, so no architecture can change what it asserts —
# checked in the pinned nixpkgs modules, where the values they name (node's
# `RestrictAddressFamilies`, smartctl's `AmbientCapabilities`, the Podman socket
# group) are set unconditionally. They are registered once on the canonical
# system rather than once per architecture, and each still stays within the
# per-leaf NixOS evaluator budget.
{
  lib,
  config,
  inputs,
  ...
}:
let
  aspects = config.flake.modules.nixos;

  canonicalSystem = "x86_64-linux";

  inherit
    (import ../../lib/contract-leaf.nix {
      inherit lib;
      pkgs = inputs.nixpkgs.legacyPackages.${canonicalSystem};
    })
    leaf
    assertionFailures
    ;

  hostFor =
    system: modules:
    (lib.nixosSystem {
      inherit system;
      modules = [
        inputs.sops-nix.nixosModules.sops
        { system.stateVersion = "25.11"; }
        {
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "nodev";
            fsType = "tmpfs";
          };
        }
      ]
      ++ modules;
    }).config;

  node = hostFor canonicalSystem [ aspects.node-exporter ];
  # Same aspect, ordinary consumer list additions and the deliberate
  # replacement escape: the composed seam the default host alone cannot show.
  nodeConsumerAdds = hostFor canonicalSystem [
    aspects.node-exporter
    { services.prometheus.exporters.node.enabledCollectors = [ "textfile" ]; }
  ];
  nodeConsumerForce = hostFor canonicalSystem [
    aspects.node-exporter
    { services.prometheus.exporters.node.enabledCollectors = lib.mkForce [ "textfile" ]; }
  ];
  tailscale = hostFor canonicalSystem [ aspects.tailscale ];
  smart = hostFor canonicalSystem [ aspects.smartctl-exporter ];
  smartOverride = hostFor canonicalSystem [
    aspects.smartctl-exporter
    { services.prometheus.exporters.smartctl.port = 19633; }
  ];
  process = hostFor canonicalSystem [
    aspects.process-exporter
    {
      services.prometheus.exporters.process.settings.process_names = [
        {
          name = "fixture";
          comm = [ "fixture" ];
        }
      ];
    }
  ];
  processOverride = hostFor canonicalSystem [
    aspects.process-exporter
    {
      services.prometheus.exporters.process = {
        port = 19256;
        settings.process_names = [
          {
            name = "fixture";
            comm = [ "fixture" ];
          }
        ];
      };
    }
  ];
  processMissing = hostFor canonicalSystem [ aspects.process-exporter ];
in
{
  flake.checks.${canonicalSystem} = {
    node-tailscale-exporters = leaf "node-tailscale-exporters" [
      {
        message = "node-exporter did not enable systemd collection on the existing exporter or retain its listener/registration join";
        ok =
          let
            native = node.services.prometheus.exporters.node;
            scrape = node.services.telemetry.scrape.node;
          in
          builtins.elem "systemd" native.enabledCollectors
          && scrape.target == native.listenAddress
          && scrape.port == native.port
          && node.systemd.services."prometheus-node-exporter".serviceConfig.ExecStart != ""
          && !(builtins.elem native.port node.networking.firewall.allowedTCPPorts);
      }
      {
        message = "Tailscale metrics registration no longer targets the daemon endpoint or opened network exposure";
        ok =
          let
            scrape = tailscale.services.telemetry.scrape.tailscale;
            flags = tailscale.services.tailscale.extraSetFlags ++ tailscale.services.tailscale.extraUpFlags;
          in
          scrape.target == "100.100.100.100"
          && scrape.port == 80
          && scrape.metricsPath == "/metrics"
          && !(builtins.elem "--webclient" flags)
          && !tailscale.services.tailscale.openFirewall
          && !(builtins.elem 80 tailscale.networking.firewall.allowedTCPPorts);
      }
      {
        message = "a Tailscale source stopped being dormant without a metrics realization";
        ok =
          (tailscale.services.telemetry.scrape ? tailscale)
          && !(tailscale.systemd.services ? vmagent)
          && !(tailscale.systemd.services ? opentelemetry-collector);
      }
    ];

    # The composition seam a consumer actually crosses: an ordinary collector
    # addition rides on the fleet's systemd entry, and `mkForce` still replaces
    # it. The default-host leaf above cannot show either.
    node-exporter-collector-composition = leaf "node-exporter-collector-composition" [
      {
        message = "an ordinary consumer collector addition replaced the fleet systemd collector, or the native module stopped deriving DBus socket access from the effective list";
        ok =
          let
            native = nodeConsumerAdds.services.prometheus.exporters.node;
            families =
              nodeConsumerAdds.systemd.services."prometheus-node-exporter".serviceConfig.RestrictAddressFamilies
                or [ ];
          in
          native.enabledCollectors == [
            "textfile"
            "systemd"
          ]
          && builtins.elem "AF_UNIX" families;
      }
      {
        message = "the deliberate mkForce replacement no longer removes the fleet collector from the effective list";
        ok =
          let
            native = nodeConsumerForce.services.prometheus.exporters.node;
            families =
              nodeConsumerForce.systemd.services."prometheus-node-exporter".serviceConfig.RestrictAddressFamilies
                or [ ];
          in
          native.enabledCollectors == [ "textfile" ] && !(builtins.elem "AF_UNIX" families);
      }
    ];

    smartctl-exporter-composition = leaf "smartctl-exporter-composition" [
      {
        message = "SMART listener/registration diverged, native capabilities were lost, or the endpoint reached the firewall";
        ok =
          let
            native = smart.services.prometheus.exporters.smartctl;
            scrape = smart.services.telemetry.scrape.smartctl;
            unit = smart.systemd.services."prometheus-smartctl-exporter";
          in
          scrape.target == native.listenAddress
          && scrape.port == native.port
          && native.listenAddress == "127.0.0.1"
          &&
            unit.serviceConfig.AmbientCapabilities == [
              "CAP_SYS_RAWIO"
              "CAP_SYS_ADMIN"
            ]
          && !(builtins.elem native.port smart.networking.firewall.allowedTCPPorts);
      }
      {
        message = "SMART consumer port override did not move the exporter and registration together";
        ok =
          smartOverride.services.prometheus.exporters.smartctl.port == 19633
          && smartOverride.services.telemetry.scrape.smartctl.port == 19633;
      }
    ];

    process-exporter-composition = leaf "process-exporter-composition" [
      {
        message = "process exporter listener/registration diverged or its native consumer selector was lost";
        ok =
          let
            native = process.services.prometheus.exporters.process;
            scrape = process.services.telemetry.scrape.process;
          in
          scrape.target == native.listenAddress
          && scrape.port == native.port
          && native.listenAddress == "127.0.0.1"
          &&
            native.settings.process_names == [
              {
                name = "fixture";
                comm = [ "fixture" ];
              }
            ]
          && !(builtins.elem native.port process.networking.firewall.allowedTCPPorts);
      }
      {
        message = "process exporter port override did not move its listener and registration together";
        ok =
          processOverride.services.prometheus.exporters.process.port == 19256
          && processOverride.services.telemetry.scrape.process.port == 19256;
      }
      {
        message = "process exporter accepted empty selectors without the named failure";
        ok = builtins.any (lib.hasPrefix "process-exporter: services.prometheus.exporters.process.settings.process_names is empty") (
          assertionFailures processMissing
        );
      }
    ];
  };
}
