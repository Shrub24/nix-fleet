# Focused NixOS evaluations for collector-owned contracts. These cases compose
# the collector because the resource processor branch exists in its realization
# helper and the secret assertions inspect its generated runtime wiring.
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
      inherit (import ../../lib/contract-leaf.nix { inherit lib pkgs; }) leaf assertionFailures;
      # Telemetry values and the collector's own option surface are separate
      # namespaces: the processor order is declared on the collector.
      hostFor =
        values: collector:
        (lib.nixosSystem {
          inherit system;
          modules = [
            inputs.sops-nix.nixosModules.sops
            config.flake.modules.nixos.telemetry-otel-collector-otlp
            { services.telemetry = values; }
            { services.otel-collector = collector; }
            { system.stateVersion = "25.11"; }
          ];
        }).config;
      fixtureSecretFile = ../flake/fixture-secrets.yaml;
      base = {
        otlp.signals = [ "traces" ];
        destinations.local = {
          protocol = "otlp-grpc";
          endpoint = "http://gateway.invalid:4317";
          signals = [ "traces" ];
        };
      };
      rawResource = hostFor base {
        resourceAttributes."host.name" = "fixture-host";
        processors.resource.attributes = [
          {
            key = "k";
            value = "v";
            action = "upsert";
          }
        ];
      };
      manualResource =
        (hostFor base {
          processors.resource.attributes = [
            {
              key = "k";
              value = "v";
              action = "upsert";
            }
          ];
        }).services.opentelemetry-collector.settings.service.pipelines.traces.processors;
      unbound = hostFor base { };
      inactive = hostFor (
        base
        // {
          destinations.active = {
            protocol = "otlp-http";
            endpoint = "https://backend.invalid";
            signals = [ "traces" ];
            headers.Authorization.secret = "activeToken";
          };
          destinations.logsOnly = {
            protocol = "otlp-http";
            endpoint = "https://logs.invalid";
            signals = [ "logs" ];
            headers.Authorization.secret = "idleToken";
          };
          secretFiles = {
            activeToken = fixtureSecretFile;
            idleToken = fixtureSecretFile;
          };
          secretKeys = {
            activeToken = "otel/active";
            idleToken = "otel/idle";
          };
        }
      ) { };
      inactiveCollector = inactive.services.opentelemetry-collector;
    in
    {
      checks = {
        otel-collector-resource-order = leaf "otel-collector-resource-order" [
          {
            message = "a raw processors.resource declaration is no longer rejected when resourceAttributes is also declared";
            ok = builtins.any (lib.hasPrefix "otel-collector: configure the resource processor through resourceAttributes, not processors.resource") (
              assertionFailures rawResource
            );
          }
          {
            message = "a directly declared resource processor no longer reaches the pipeline order";
            ok =
              manualResource == [
                "memory_limiter"
                "resource"
                "resource/telemetry-identity"
              ];
          }
        ];
        otel-collector-unbound-secrets = leaf "otel-collector-unbound-secrets" [
          {
            message = "an unbound credential registered a secret or EnvironmentFile, or removed the plain exporter";
            ok =
              !(builtins.any (name: lib.hasPrefix "otel-collector/" name) (
                builtins.attrNames unbound.sops.secrets
              ))
              && !(unbound.sops.templates ? "otel-collector.env")
              && !(unbound.systemd.services.opentelemetry-collector.serviceConfig ? EnvironmentFile)
              && unbound.services.opentelemetry-collector.settings.exporters ? "otlp/local";
          }
        ];
        otel-collector-inactive-credentials = leaf "otel-collector-inactive-credentials" [
          {
            message = "a dormant destination's bound credential leaked an exporter, secret or override";
            ok =
              builtins.attrNames inactiveCollector.settings.exporters == [ "otlphttp/active" ]
              && builtins.attrNames inactive.sops.secrets == [ "otel-collector/activeToken" ]
              &&
                inactive.sops.templates."otel-collector.env".content
                == "OTELCOL_activeToken=${inactive.sops.placeholder."otel-collector/activeToken"}\n"
              &&
                inactiveCollector.validateConfigOverrides == [
                  "exporters::otlphttp/active::headers::Authorization=stub"
                ];
          }
        ];
      };
    };
}
