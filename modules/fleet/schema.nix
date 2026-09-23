# Fleet schema: the typed namespaces nix-fleet is canonical authority for.
# Tier 1 (canonical fact): fleet.hosts (identity + machine capabilities),
# fleet.externalBuilders (externally provided build resources),
# fleet.buildProfiles (cross-fleet scheduling policy).
# Tier 2 (shared default): mechanism defaults below (endpoint user, tuning).
# Tier 3 (consumer-local): everything else a consumer keeps in its own tree.
{ lib, ... }:
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
              description = "Target system the host builds natively; null for identity-only hosts. Canonical fact — builder records derive from it, never restate it.";
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

            capabilities.nixBuilder = {
              enable = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "This host participates in remote build dispatch. A capability of the machine, not a scheduling decision — profiles select it.";
              };

              maxJobs = lib.mkOption {
                type = lib.types.ints.positive;
                default = 1;
                description = "Default concurrent-builds budget; a profile member override wins over it.";
              };

              speedFactor = lib.mkOption {
                type = lib.types.ints.positive;
                default = 1;
                description = "Relative speed hint for nix's builder ranking.";
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

              extraSystems = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = "Explicit exception to the host's system: additional/emulated systems this host also builds.";
              };

              endpoint.user = lib.mkOption {
                type = lib.types.str;
                default = "nixbuild";
                description = "User remote coordinators dial as. Fleet convention: the dedicated dispatch account (build-account aspect), least-privilege and revocable — not a general-purpose user.";
              };

              endpoint.protocol = lib.mkOption {
                type = lib.types.enum [ "ssh-ng" ];
                default = "ssh-ng";
                description = "Store protocol for the builder connection.";
              };
            };
          };
        }
      );
      default = { };
      description = "Canonical fleet machine identity and capabilities: who a host is and what it can do. nix-fleet is the authority; consumers derive, never restate.";
    };

    externalBuilders = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            uri = lib.mkOption {
              type = lib.types.str;
              description = "Full store URI, e.g. ssh-ng://eu.nixbuild.net.";
            };

            systems = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Systems this resource can build.";
            };

            publicHostKey = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "SSH host key; there is no host record to inherit from, so trust requires it here.";
            };

            hostNames = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Names for known-hosts/Host blocks; defaults to the URI's host part.";
            };

            sshUser = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Dial user; null lets a profile member override (or the consumer adapter) set it.";
            };

            metered = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Usage is billed; scheduling this resource is an explicit profile-membership act.";
            };

            speedFactor = lib.mkOption {
              type = lib.types.ints.positive;
              default = 1;
              description = "Relative speed hint for nix's builder ranking.";
            };
          };
        }
      );
      default = { };
      description = "Externally provided build resources. Deliberately narrow — Den can turn these into proper entities later.";
    };

    buildProfiles = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            hosts = lib.mkOption {
              type = lib.types.attrsOf (
                lib.types.submodule {
                  options = {
                    maxJobs = lib.mkOption {
                      type = lib.types.nullOr lib.types.ints.positive;
                      default = null;
                      description = "Override for this relationship; null = the host capability's default.";
                    };
                    speedFactor = lib.mkOption {
                      type = lib.types.nullOr lib.types.ints.positive;
                      default = null;
                    };
                    supportedFeatures = lib.mkOption {
                      type = lib.types.nullOr (lib.types.listOf lib.types.str);
                      default = null;
                    };
                    mandatoryFeatures = lib.mkOption {
                      type = lib.types.nullOr (lib.types.listOf lib.types.str);
                      default = null;
                    };
                  };
                }
              );
              default = { };
              description = "Fleet-host members. Presence is membership; fields are per-relationship overrides.";
            };

            external = lib.mkOption {
              type = lib.types.attrsOf (
                lib.types.submodule {
                  options = {
                    maxJobs = lib.mkOption {
                      type = lib.types.nullOr lib.types.ints.positive;
                      default = null;
                      description = "Per-relationship budget — for metered resources this is the cost knob.";
                    };
                    speedFactor = lib.mkOption {
                      type = lib.types.nullOr lib.types.ints.positive;
                      default = null;
                    };
                    sshUser = lib.mkOption {
                      type = lib.types.nullOr lib.types.str;
                      default = null;
                    };
                  };
                }
              );
              default = { };
              description = "External-resource members; same membership-by-presence, override-by-field shape.";
            };
          };
        }
      );
      default = { };
      description = "Named scheduling policies binding workloads to builders. Scheduling parameters belong to the relationship between workload and builder, hence per-member overrides. Cross-fleet profiles are canonical here; consumer-local profiles are additive downstream.";
    };
  };
}
