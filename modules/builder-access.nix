# Aspect: builder-access — remote-builder SSH trust (OPS-7).
#
# Extracted from nix-homelab's `builder-access` aspect plus its private
# `nixbuild-ssh` leaf. The mechanism stays here: trusted host keys and the SSH
# client tuning that keeps long remote builds alive. The builder endpoint, its
# host key, and any substituted build policy are consumer policy — this aspect
# carries no provider hostname, URL, or key literal.
#
# Substituter policy deliberately stays out: a consumer that wants the builder
# as a substituter configures that in its own base aspect.
_: {
  flake.modules.nixos.builder-access =
    { config, lib, ... }:
    let
      cfg = config.services.builder-access;

      # Conventional defaults carried over from the extracted source; a consumer
      # overrides individual options per builder when its endpoint needs it.
      defaultSshOptions = {
        IPQoS = "throughput";
        PubkeyAcceptedKeyTypes = "ssh-ed25519";
        ServerAliveInterval = "60";
        TCPKeepAlive = "no";
        Compression = "no";
        ControlMaster = "auto";
        ControlPath = "/tmp/builder-access-%r@%h:%p";
        ControlPersist = "10m";
      };

      hostBlock = _name: builder: ''
        Host ${lib.concatStringsSep " " builder.hostNames}
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (key: value: "  ${key} ${value}") builder.sshOptions
        )}
      '';
    in
    {
      options.services.builder-access.hosts = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              hostNames = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = "Host names and aliases this builder answers to.";
              };

              publicKey = lib.mkOption {
                type = lib.types.str;
                description = "SSH host public key trusted for this builder, taken from the builder's own documentation.";
              };

              sshOptions = lib.mkOption {
                type = lib.types.attrsOf lib.types.str;
                default = defaultSshOptions;
                description = "SSH client options rendered into this builder's `Host` block.";
              };
            };
          }
        );
        default = { };
        description = "Remote builders to trust, keyed by the known-hosts entry name.";
      };

      config = {
        assertions = [
          {
            assertion = cfg.hosts != { };
            message = "builder-access: services.builder-access.hosts is empty; bind at least one remote builder endpoint.";
          }
          {
            assertion = lib.all (builder: builder.hostNames != [ ]) (lib.attrValues cfg.hosts);
            message = "builder-access: every services.builder-access.hosts.<name> needs at least one entry in hostNames.";
          }
        ];

        programs.ssh.knownHosts = lib.mapAttrs (_name: builder: {
          inherit (builder) hostNames publicKey;
        }) cfg.hosts;

        programs.ssh.extraConfig = lib.concatStringsSep "\n" (lib.mapAttrsToList hostBlock cfg.hosts);
      };
    };
}
