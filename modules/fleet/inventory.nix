# Canonical fleet inventory: the facts that must agree everywhere. Declared by
# nix-fleet itself (the authority); consumers derive from these and add only
# their own local policy. SSH host keys are read from each host's own
# /etc/ssh/ssh_host_ed25519_key.pub, never from a live scan; eu.nixbuild.net's
# key is from its official docs.
_: {
  fleet = {
    hosts = {
      home-forge = {
        system = "x86_64-linux";
        tailscale.hostname = "home-forge";
        hostNames = [ "home-forge" ];
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILre5rGGN4yjhV8XJpREgl+BRdru24t8NZgHTvpgouKf root@home-forge";
      };
      la-admin-1 = {
        system = "x86_64-linux";
        tailscale.hostname = "la-admin-1";
        hostNames = [ "la-admin-1" ];
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINNXbGpZyizRCUVdjz35hFTmoWLgM8TPwGbQjCvrrcER root@nixos";
      };
      oci-melb-1 = {
        system = "aarch64-linux";
        tailscale.hostname = "oci-melb-1";
        hostNames = [ "oci-melb-1" ];
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC8NW1V+x+tvbwzPMEcGRlK2V1XXAuDgdJ2dUQssiWaC root@oci-melb-1";
      };
    };

    builders.home-forge = {
      host = "home-forge";
      systems = [ "x86_64-linux" ];
      maxJobs = 4;
      speedFactor = 2;
      supportedFeatures = [
        "big-parallel"
        "kvm"
        "nixos-test"
      ];
    };

    builders.la-admin-1 = {
      host = "la-admin-1";
      systems = [ "x86_64-linux" ];
      maxJobs = 2;
      speedFactor = 1;
      supportedFeatures = [ ];
    };

    builders.nixbuild = {
      uri = "ssh-ng://eu.nixbuild.net";
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      hostNames = [ "eu.nixbuild.net" ];
      publicHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPIQCZc54poJ8vqawd8TraNryQeJnvH1eLpIDgbiqymM";
    };

    builders.oci-melb-1 = {
      host = "oci-melb-1";
      systems = [ "aarch64-linux" ];
      maxJobs = 4;
      speedFactor = 2;
      supportedFeatures = [ "big-parallel" ];
    };

    builderSets.ci = [
      "home-forge"
      "nixbuild"
    ];

    # Every fleet host that can build. A set is a selection, not an
    # architecture: each builder declares the systems it serves, so one
    # arch-agnostic set dispatches correctly on its own — a per-architecture
    # split would only encode a restriction (never fall back to a builder that
    # emulates), which no record here needs. `ci` stays as nix-fleet's own CI
    # set; consumers that build on the fleet select this one.
    builderSets.all-hosts = [
      "home-forge"
      "la-admin-1"
      "oci-melb-1"
    ];
  };
}
