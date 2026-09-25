# Mosh for tailnet-interactive sessions. openFirewall = false is deliberate:
# mosh's UDP range is opened upstream by default, which would punch a hole
# in every consumer's firewall — exposure is the network aspect's/consumer's
# call, not the mechanism's. Tailnet-only use needs no firewall opening at
# all (the tailscale interface is trusted).
{
  flake.modules.nixos.mosh = {
    programs.mosh = {
      enable = true;
      openFirewall = false;
    };
  };
}
