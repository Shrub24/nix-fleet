# Fleet schema: the typed namespaces nix-fleet is canonical authority for.
# Tier 1 (canonical fact): fleet.hosts (identity), fleet.builders
# (participation), fleet.builderSets (cross-fleet scheduling policy).
# Tier 2 (shared default): the mechanism defaults below (ssh tuning, maxJobs).
# Tier 3 (consumer-local): everything else a consumer keeps in its own tree.
{ lib, ... }:
let
  # Conventional long-build ssh tuning; a builder overrides per endpoint.
  defaultSshOptions = {
    IPQoS = "throughput";
    PubkeyAcceptedKeyTypes = "ssh-ed25519";
    ServerAliveInterval = "60";
    TCPKeepAlive = "no";
    Compression = "no";
  };
in
{
  options.fleet = {
    hosts = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            system = lib.mkOption {
              type = lib.types.nullOr (
                lib.types.enum [
                  "x86_64-linux"
                  "aarch64-linux"
                ]
              );
              default = null;
              description = "Target system; null for hosts that only participate as builders. Canonical fact.";
            };

            tailscale.hostname = lib.mkOption {
              type = lib.types.str;
              description = "Tailscale machine hostname; MagicDNS resolves it tailnet-wide. Canonical fact.";
            };

            hostNames = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Names this host answers to in known-hosts entries (machine hostname plus aliases).";
            };

            publicKey = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "SSH host public key; null until the host's key is bound (deploy -> harvest -> bind). Canonical fact.";
            };
          };
        }
      );
      default = { };
      description = "Canonical fleet machine identity: who a host is. nix-fleet is the authority; consumers derive, never restate.";
    };

    builders = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            host = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Key of the fleet host backing this builder (fleet.hosts). Variant 1.";
            };

            uri = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Full store URI for externally provided builders, e.g. ssh-ng://eu.nixbuild.net; exactly one of host/uri. Variant 2.";
            };

            hostNames = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Names this builder answers to in known-hosts entries; defaults to the address's host part.";
            };

            publicHostKey = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "SSH host key for externally provided builders; fleet-host builders inherit the host's key instead.";
            };

            systems = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Systems this builder can build, comma-joined in the machines file.";
            };

            maxJobs = lib.mkOption {
              type = lib.types.ints.positive;
              default = 1;
              description = "Concurrent builds nix may dispatch to this builder (shared default).";
            };

            speedFactor = lib.mkOption {
              type = lib.types.ints.positive;
              default = 1;
              description = "Relative speed hint for nix's builder ranking (shared default).";
            };

            supportedFeatures = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Features derivations may require (big-parallel, kvm, nixos-test).";
            };

            mandatoryFeatures = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Features every derivation sent here must require.";
            };

            sshUser = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "User this builder is dialed as; null falls back to services.fleet-builders.sshUser. Canonical convention: dev (in trusted-users on fleet hosts).";
            };

            sshKeyPath = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Path of the private key the connecting host uses; a credential reference, not a credential. null uses agent/default IdentityFile config.";
            };

            sshOptions = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = defaultSshOptions;
              defaultText = "conventional long-build tuning (IPQoS, keepalives, ed25519)";
              description = "ssh client options for this builder's Host block (shared default).";
            };
          };
        }
      );
      default = { };
      description = "Canonical builder participation records. nix-fleet is the authority.";
    };

    builderSets = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = { };
      description = "Named builder sets: the one scheduling-policy mechanism. Cross-fleet sets (e.g. ci) are canonical here; consumer-local sets are additive downstream. Metered/external resources are spent only by explicit set membership.";
    };

    realization = lib.mkOption {
      type = lib.types.nullOr lib.types.raw;
      default = null;
      internal = true;
      description = ''
        The NixOS-class realization constructed in this evaluation with the
        merged fleet config closed over. Host compositions import
        config.fleet.realization; it is never published as a pre-realized
        module.
      '';
    };
  };
}
