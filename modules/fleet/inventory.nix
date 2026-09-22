# Canonical fleet inventory: the facts that must agree everywhere. Declared by
# nix-fleet itself (the authority); consumers derive from these and add only
# their own local policy. SSH host keys bind after first deploy (null = not yet
# harvested); eu.nixbuild.net's key is from its official docs.
_: {
  fleet = {
    hosts = {
      home-forge = {
        system = "x86_64-linux";
        tailscale.hostname = "home-forge";
        hostNames = [ "home-forge" ];
      };
      la-admin-1 = {
        system = "x86_64-linux";
        tailscale.hostname = "la-admin-1";
        hostNames = [ "la-admin-1" ];
      };
      oci-melb-1 = {
        system = "aarch64-linux";
        tailscale.hostname = "oci-melb-1";
        hostNames = [ "oci-melb-1" ];
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

    builders.nixbuild = {
      uri = "ssh-ng://eu.nixbuild.net";
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      hostNames = [ "eu.nixbuild.net" ];
      publicHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPIQCZc54poJ8vqawd8TraNryQeJnvH1eLpIDgbiqymM";
    };

    builderSets.ci = [
      "home-forge"
      "nixbuild"
    ];
  };
}
