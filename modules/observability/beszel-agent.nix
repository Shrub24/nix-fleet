# Beszel agent authentication and enrollment. The hub stays consumer-side.
# The KEY is the PUBLIC half of the hub's SSH keypair — the agent verifies
# the hub against it, so it is policy data, not a secret (the hub's private
# key never leaves the hub). TOKEN (the WebSocket registration path) is
# deliberately not wired: WebSocket mode needs plain HTTP reachability of
# the hub URL, but the hub sits behind Cloudflare Access and agents reach
# it over tailnet SSH — no HUB_URL, no TOKEN.
{
  flake.modules.nixos.beszel-agent =
    { config, lib, ... }:
    let
      cfg = config.services.beszel-agent;
    in
    {
      # Registration is unconditional in the class: the shared fragment declares
      # the namespace, and the notify aspect realizes it only when co-selected —
      # the same idiom the maintenance aspects use for their own units.
      imports = [ ../notifications/notify/_notify-events.nix ];

      options.services.beszel-agent = {
        enable = lib.mkEnableOption "the Beszel monitoring agent (the agent holds no secret — only the hub's public key)";

        key = lib.mkOption {
          type = lib.types.str;
          description = "Public SSH key the hub authenticates with (the fleet-wide KEY). Public data: upstream's environment.KEY lands it in the unit's Environment=, in the /nix/store — fine, because it is public.";
        };
      };

      config = lib.mkIf cfg.enable {
        services.beszel.agent = {
          enable = true;
          environment.KEY = cfg.key;
        };

        services.notify.events."beszel-agent".failure = { };
      };
    };
}
