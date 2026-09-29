# Host-local telemetry — the ONE public aspect a host selects. Selection is
# enablement. It realizes the `services.telemetry` contract with the
# implementation each capability selects (`services.telemetry.providers.*`,
# defaulting to the adapters shipped under _providers/), and it always performs
# source admission: an orphan registration — a scrape source, a destination, or
# a journald sink written without this aspect — fails closed by name in the
# contract fragment.
#
# Implementations are private modules under telemetry/_providers/, not separate
# public aspects: swapping one is a `services.telemetry.providers.*` value, not
# an imports-list edit. A capability may select a different implementation than
# another later; today each capability has exactly one implemented value, so the
# provider enums name them and an unimplemented value is a contract edit rather
# than a host typo.
_: {
  flake.modules.nixos.telemetry =
    { ... }:
    {
      imports = [
        ./telemetry/_contract.nix
        ./telemetry/_providers/otel-collector.nix
        ./telemetry/_providers/vector.nix
      ];

      config.services.telemetry.realized = true;
    };
}
