# Signal lanes are the consumer-facing defaults: composing a lane selects its
# fleet realization without asking hosts to name an implementation.
{ config, ... }:
let
  aspects = config.flake.modules.nixos;
in
{
  flake.modules.nixos.telemetry-metrics = {
    imports = [
      aspects.telemetry
      aspects.telemetry-vmagent
    ];
  };

  flake.modules.nixos.telemetry-logs = {
    imports = [
      aspects.telemetry
      aspects.telemetry-vector
    ];
  };

  flake.modules.nixos.telemetry-otlp = {
    imports = [
      aspects.telemetry
      aspects.telemetry-otel-collector-otlp
    ];
  };
}
