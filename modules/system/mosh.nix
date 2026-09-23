# Mosh for tailnet-interactive sessions; the UDP range is tailnet-scoped
# upstream, so no openFirewall here — the network aspect owns exposure.
_: {
  flake.modules.nixos.mosh = {
    programs.mosh.enable = true;
  };
}
