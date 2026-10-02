# The host-local telemetry aspect: the ONE public aspect a host selects.
# Selection is enablement.
#
# This file declares the aspect itself (contract + realization marker); the
# implementations are sibling flake-parts contributors in this directory
# (`otel-collector.nix`, `vmagent.nix`, `vector.nix`) that merge the same
# `flake.modules.nixos.telemetry` deferred module. Siblings never import one
# another, and no implementation is exported as a second public aspect: swapping
# one is a `services.telemetry.providers.*` value, not an imports-list edit.
#
# Source admission is unconditional: an orphan registration — a scrape source,
# a destination, or a journald sink written without this aspect — fails closed
# by name in the contract fragment.
_: {
  flake.modules.nixos.telemetry =
    { ... }:
    {
      imports = [ ../../lib/telemetry-contract.nix ];

      config.services.telemetry.realized = true;
    };
}
