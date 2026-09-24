# Canonical fleet inventory: the facts that must agree everywhere. Declared by
# nix-fleet itself (the authority); consumers derive from these and add only
# their own local policy. SSH host keys are read from each host's own
# /etc/ssh/ssh_host_ed25519_key.pub, never from a live scan; eu.nixbuild.net's
# key is from its official docs.
_: {
  fleet = {
    hosts = {
      home-forge = {
        managementUser = "dev";
        system = "x86_64-linux";
        tailscale.hostname = "home-forge";
        hostNames = [ "home-forge" ];
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILre5rGGN4yjhV8XJpREgl+BRdru24t8NZgHTvpgouKf root@home-forge";

        capabilities.nixBuilder = {
          enable = true;
          maxJobs = 4;
          speedFactor = 2;
          supportedFeatures = [
            "big-parallel"
            "kvm"
            "nixos-test"
          ];
        };
      };

      la-admin-1 = {
        managementUser = "dev";
        system = "x86_64-linux";
        tailscale.hostname = "la-admin-1";
        hostNames = [ "la-admin-1" ];
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINNXbGpZyizRCUVdjz35hFTmoWLgM8TPwGbQjCvrrcER root@nixos";

        capabilities.nixBuilder = {
          enable = true;
          maxJobs = 2;
        };
      };

      oci-melb-1 = {
        managementUser = "dev";
        system = "aarch64-linux";
        tailscale.hostname = "oci-melb-1";
        hostNames = [ "oci-melb-1" ];
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC8NW1V+x+tvbwzPMEcGRlK2V1XXAuDgdJ2dUQssiWaC root@oci-melb-1";

        capabilities.nixBuilder = {
          enable = true;
          maxJobs = 4;
          speedFactor = 2;
          supportedFeatures = [ "big-parallel" ];
        };
      };

      # Workstations: identity and trust only. Neither offers build capacity,
      # so neither carries capabilities.nixBuilder.
      legion = {
        system = "x86_64-linux";
        tailscale.hostname = "legion";
        hostNames = [ "legion" ];
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFsK69xOk2uqJ1njVF/Bc60NVnbptb9A3wxDZs5qfPqQ root@arch";
      };

      spectre = {
        system = "x86_64-linux";
        tailscale.hostname = "spectre";
        hostNames = [ "spectre" ];
        # publicKey unbound: the laptop is not installed yet. Bind after first
        # deploy, per the hosts contract's deploy -> harvest -> bind flow.
      };
    };

    externalBuilders.nixbuild = {
      uri = "ssh-ng://eu.nixbuild.net";
      sshUser = "root";
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      hostNames = [ "eu.nixbuild.net" ];
      publicHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPIQCZc54poJ8vqawd8TraNryQeJnvH1eLpIDgbiqymM";
      metered = true;
    };

    # Canonical cross-fleet profiles. A profile is a scheduling policy:
    # which builders a workload class may use, and the per-relationship
    # parameters. Ordinary CI runs on the free/background fleet; the metered
    # external joins only through an explicitly named profile (arm-expensive),
    # so nixbuild participation is always visible in the workload's name.
    buildProfiles.ci = {
      hosts.home-forge = { };
      hosts.la-admin-1 = { };
      hosts.oci-melb-1 = { };
    };
    buildProfiles.arm-expensive = {
      hosts.oci-melb-1 = { };
      external.nixbuild.maxJobs = 4;
    };
  };
}
