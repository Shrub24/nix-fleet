# Fixture evaluation class: exercises every aspect on a throwaway NixOS target
# so `nix flake check` catches option/merge breakage without real hosts.
#
# The fixture is deliberately consumer-shaped: it imports the upstream modules
# the aspects expect a consumer to supply (sops-nix for secret delivery, the
# niks3 module for the cache server) and binds obviously-fake placeholder
# values. Secret-file bindings point at a source file that already exists in
# the store, which is all the aspects' existence gate asks for; this fixture is
# never activated and never decrypts anything.
{ config, inputs, ... }:
let
  # Stand-in for a consumer's SOPS files: an existing path in the flake source,
  # so the existence gates fire without committing a fake secret file.
  fixtureSecretFile = ./. + "/fixture.nix";

  # Placeholder age key path. sops-nix requires a configured key source and
  # rejects store paths for it; nothing here is ever activated, so this file
  # never has to exist.
  fixtureAgeKeyFile = "/run/secrets/fixture-age-key";

  aspects = config.flake.modules.nixos;
in
{
  configurations.nixos.fixture.module =
    { config, ... }:
    {
      imports = [
        inputs.sops-nix.nixosModules.sops
        inputs.niks3.nixosModules.niks3
      ]
      ++ (with aspects; [
        beszel-agent
        builder-access
        niks3-cache
        tailscale
      ]);

      nixpkgs.hostPlatform = "x86_64-linux";
      boot.loader.grub.enable = false;
      fileSystems."/" = {
        device = "nodev";
        fsType = "tmpfs";
      };
      system.stateVersion = "25.11";

      sops.age.keyFile = fixtureAgeKeyFile;

      # Non-vacuity guard: a fixture that evaluates with silently inert aspects
      # is exactly the failure this class exists to catch, so each aspect has to
      # show its contribution.
      assertions = [
        {
          assertion = config.services.beszel.agent.enable;
          message = "fixture: the beszel-agent aspect registered no agent; its secret-file gate did not fire.";
        }
        {
          assertion = config.services.tailscale.authKeyFile != null;
          message = "fixture: the tailscale aspect wired no auth key file.";
        }
        {
          assertion = config.services.niks3.enable && config.services.niks3.apiTokenFile != null;
          message = "fixture: the niks3-cache aspect did not configure the cache server.";
        }
        {
          assertion = config.programs.ssh.knownHosts != { };
          message = "fixture: the builder-access aspect registered no known host.";
        }
      ];

      services = {
        beszel-agent.secretFiles = {
          common = fixtureSecretFile;
          host = fixtureSecretFile;
        };

        builder-access.hosts.fixture-builder = {
          hostNames = [ "builder.invalid" ];
          # Placeholder key material: no real builder endpoint or host key
          # belongs in this repository.
          publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIxTuRe0000000000000000000000000000000000 fixture@invalid";
        };

        niks3-cache = {
          s3.endpoint = "s3.invalid";
          cacheUrl = "https://cache.invalid";
          secretFiles = {
            host = fixtureSecretFile;
            apiToken = fixtureSecretFile;
          };
        };

        tailscale.secretFiles.auth = fixtureSecretFile;
      };
    };
}
