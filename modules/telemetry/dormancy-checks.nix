# The contract accepts inert declaration families until a realization consumes them.
{
  lib,
  config,
  inputs,
  ...
}:
{
  perSystem =
    { system, ... }:
    let
      pkgs = inputs.nixpkgs.legacyPackages.${system};
      check = import ../../lib/contract-leaf.nix { inherit lib pkgs; };
      inherit (check) leaf telemetryAccepts;
      aspects = config.flake.modules.nixos;
      # nixpkgs' own boot assertions are not the claim under test.
      fixtureHost = {
        boot.loader.grub.enable = false;
        fileSystems."/" = {
          device = "nodev";
          fsType = "tmpfs";
        };
      };
      acceptsComposition =
        modules: values:
        let
          host =
            (lib.nixosSystem {
              inherit system;
              modules = modules ++ [
                { services.telemetry = values; }
                { system.stateVersion = "25.11"; }
                fixtureHost
              ];
            }).config;
        in
        (builtins.tryEval (lib.asserts.checkAssertWarn host.assertions host.warnings true)).success;
    in
    {
      checks.telemetry-dormant-declarations = leaf "telemetry-dormant-declarations" [
        {
          message = "a contract-only registered source without realization is no longer accepted";
          ok = telemetryAccepts {
            scrape.app = {
              target = "127.0.0.1";
              port = 9100;
            };
          };
        }
        {
          message = "a contract-only destination without realization is no longer accepted";
          ok = telemetryAccepts {
            destinations.x = {
              protocol = "otlp-grpc";
              endpoint = "http://x.invalid:4317";
              signals = [ "traces" ];
            };
          };
        }
        {
          message = "a partial destination declaration is no longer accepted as inert data";
          ok = telemetryAccepts { destinations.x.endpoint = "http://x.invalid:4317"; };
        }
        {
          message = "the bare telemetry vocabulary is no longer accepted";
          ok = telemetryAccepts { };
        }
        {
          message = "the valid telemetry-vmagent composition no longer accepts its scrape registration";
          ok =
            acceptsComposition
              [ ../../lib/telemetry-contract.nix inputs.sops-nix.nixosModules.sops aspects.telemetry-vmagent ]
              {
                scrape.app = {
                  target = "127.0.0.1";
                  port = 9100;
                };
                destinations.local = {
                  protocol = "prometheus-remote-write";
                  endpoint = "http://metrics.invalid/api/v1/write";
                  signals = [ "metrics" ];
                };
              };
        }
        {
          message = "the plain telemetry-aspect composition no longer accepts its scrape registration";
          ok = acceptsComposition [ ../../lib/telemetry-contract.nix aspects.telemetry ] {
            scrape.app = {
              target = "127.0.0.1";
              port = 9100;
            };
            destinations.local = {
              protocol = "prometheus-remote-write";
              endpoint = "http://metrics.invalid/api/v1/write";
              signals = [ "metrics" ];
            };
          };
        }
      ];
    };
}
