# Shared host-local telemetry vocabulary and value validation. Runtime belongs
# to explicitly composed signal lanes and realization aspects.
_: {
  flake.modules.nixos.telemetry = {
    imports = [ ../../lib/telemetry-contract.nix ];
  };
}
