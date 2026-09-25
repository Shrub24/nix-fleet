# SSH baseline: the server hardening both consumer repos duplicated, plus
# the client tuning fragment for /etc/ssh/ssh_config.d. Trust is the fleet
# feature's job (known-hosts projection); per-host server policy (listen
# addresses, extra matches) stays consumer-side.
{ lib, ... }:
{
  flake.modules.nixos.ssh =
    { config, ... }:
    {
      imports = [ ../notifications/notify/_notify-events.nix ];

      options.services.ssh-baseline = {
        enable = lib.mkEnableOption "the shared SSH baseline (server hardening + client tuning)";

        clientTuning = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Render the multiplexing client fragment into /etc/ssh/ssh_config.d.";
        };
      };

      config = lib.mkIf config.services.ssh-baseline.enable {
        services.openssh = {
          enable = lib.mkDefault true;
          openFirewall = lib.mkDefault true;
          settings = {
            PasswordAuthentication = lib.mkDefault false;
            KbdInteractiveAuthentication = lib.mkDefault false;
            PermitRootLogin = lib.mkDefault "prohibit-password";
          };
        };

        environment.etc."ssh/ssh_config.d/20-fleet-baseline.conf" =
          lib.mkIf config.services.ssh-baseline.clientTuning
            {
              text = ''
                Host *
                    ServerAliveInterval 60
                    ServerAliveCountMax 3
                    TCPKeepAlive no
                    ControlMaster auto
                    ControlPersist 600
                    ControlPath ~/.ssh/ctl-%r@%h:%p
              '';
            };

        # The aspect owns the sshd hardening, so it owns the failure
        # registration. Registration is unconditional in the class; the
        # notify aspect realizes it only when co-selected.
        services.notify.events.sshd.failure = { };
      };
    };
}
