# Publishes the host-local endpoint shape (lib/local-endpoint.nix) as
# `inputs.nix-fleet.lib.localEndpoint` for consumers that declare their own
# local-service options.
{ lib, ... }:
{
  flake.lib.localEndpoint = import ../../lib/local-endpoint.nix lib;
}
