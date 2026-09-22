# Fleet builder registry: the typed SSOT for machine identity, builder
# participation, and named builder sets. Published as flakeModules.registry so
# consumers declare fleet.* in their own flake-parts evaluation, and as
# lib.registry for renderers CI consumers call directly. The NixOS realization
# is constructed by flakeModules.fleet-builders (modules/access/builder-access.nix),
# which closes over the consumer's registry.
let
  registryModule =
    {
      lib,
      config,
      ...
    }:
    let
      render = import ../../lib/registry-render.nix lib;

      # Conventional long-build ssh tuning carried over from the extracted
      # builder-access source; a builder overrides individual options per endpoint.
      defaultSshOptions = {
        IPQoS = "throughput";
        PubkeyAcceptedKeyTypes = "ssh-ed25519";
        ServerAliveInterval = "60";
        TCPKeepAlive = "no";
        Compression = "no";
      };

      sample = {
        hosts.sample-host = {
          tailscale.hostname = "fleet-host";
          hostNames = [ "fleet-host" ];
          publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE1AAAAI-sample";
        };
        builders = {
          sample-fleet = {
            host = "sample-host";
            systems = [
              "x86_64-linux"
              "aarch64-linux"
            ];
            maxJobs = 2;
            speedFactor = 2;
            supportedFeatures = [ "big-parallel" ];
            mandatoryFeatures = [ "nixos-test" ];
          };
          sample-external = {
            uri = "ssh-ng://eu.nixbuild.net";
            systems = [ "aarch64-linux" ];
            maxJobs = 4;
            sshKeyPath = "/run/nixbuild-key";
            publicHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI-sample-external";
            sshOptions = { };
          };
        };
        builderSets.default = [
          "sample-fleet"
          "sample-external"
        ];
      };

      # Named, fail-closed registry validation. Evaluated by the render check
      # and by the constructed NixOS aspect, so an invalid registry fails with
      # the specific problem in the message.
      validationErrors =
        fleet:
        let
          setMembers = lib.flatten (lib.attrValues fleet.builderSets);
          unknownSetMember = lib.filter (name: !fleet.builders ? ${name}) setMembers;
          unknownHostRef = lib.filter (b: (b.host or null) != null && !fleet.hosts ? ${b.host}) (
            lib.attrValues fleet.builders
          );
          variantViolations = lib.filter (b: ((b.host or null) != null) == ((b.uri or null) != null)) (
            lib.attrValues fleet.builders
          );
        in
        lib.concatMap (name: [
          "registry: builderSet names builder '${name}' missing from fleet.builders"
        ]) unknownSetMember
        ++ lib.concatMap (b: [
          "registry: builder references fleet host '${b.host}' missing from fleet.hosts"
        ]) unknownHostRef
        ++ lib.concatMap (_: [
          "registry: every builder must set exactly one of host or uri"
        ]) variantViolations;

      assertRegistry =
        fleet:
        let
          errors = validationErrors fleet;
        in
        if errors == [ ] then true else throw (lib.head errors);
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
                  description = "Target system; null for hosts that only participate as builders.";
                };

                tailscale.hostname = lib.mkOption {
                  type = lib.types.str;
                  description = "Tailscale machine hostname; MagicDNS resolves it tailnet-wide.";
                };

                hostNames = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                  description = "Names this host answers to in known-hosts entries (machine hostname plus aliases).";
                };

                publicKey = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "SSH host public key; null until the host's key is bound.";
                };
              };
            }
          );
          default = { };
          description = "Fleet-controlled machine identity: who a host is. No compositions, no policy.";
        };

        builders = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.submodule {
              options = {
                host = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Key of the fleet host backing this builder (fleet.hosts).";
                };

                uri = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Full store URI for externally provided builders, e.g. ssh-ng://eu.nixbuild.net; exactly one of host/uri.";
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
                  description = "Concurrent builds nix may dispatch to this builder.";
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

                sshKeyPath = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Path of the private key the connecting host uses; a credential reference, not a credential. null uses agent/default IdentityFile config.";
                };

                sshOptions = lib.mkOption {
                  type = lib.types.attrsOf lib.types.str;
                  default = defaultSshOptions;
                  defaultText = "conventional long-build tuning (IPQoS, keepalives, ed25519)";
                  description = "ssh client options for this builder's Host block.";
                };
              };
            }
          );
          default = { };
          description = "Builder participation records: how a fleet host or external service builds for us.";
        };

        builderSets = lib.mkOption {
          type = lib.types.attrsOf (lib.types.listOf lib.types.str);
          default = { };
          description = "Named builder sets: the one scheduling-policy mechanism. A set names the builders a workload may use; metered/external resources are spent only by explicit set membership.";
        };
      };

      config = {
        flake.lib.registry = render;

        perSystem =
          { pkgs, ... }:
          {
            # Renderer grammar check on sample data covering both builder
            # variants and every placeholder form; registry validation is
            # forced on the real consumer-bound registry too, so an invalid
            # inventory fails `nix flake check` with a named error.
            checks.registry-render =
              assert assertRegistry sample;
              assert assertRegistry config.fleet;
              pkgs.runCommand "registry-render-check"
                {
                  machines = render.machinesFile sample.hosts sample.builders;
                  sshConfig = render.sshConfig sample.hosts sample.builders;
                  knownHosts = builtins.toJSON (render.knownHosts sample.hosts sample.builders);
                  passAsFile = [
                    "machines"
                    "sshConfig"
                    "knownHosts"
                  ];
                }
                ''
                  awk 'NF > 0 { if (NF != 7) { print "registry: machines line has " NF " fields, expected 7"; exit 1 } }' "$machinesPath"
                  grep -qx 'ssh-ng://fleet-host x86_64-linux,aarch64-linux - 2 2 big-parallel nixos-test' "$machinesPath" \
                    || { echo "registry: fleet-host line wrong"; cat "$machinesPath"; exit 1; }
                  grep -qx 'ssh-ng://eu.nixbuild.net aarch64-linux /run/nixbuild-key 4 1 - -' "$machinesPath" \
                    || { echo "registry: external line wrong"; cat "$machinesPath"; exit 1; }
                  grep -qx 'Host eu.nixbuild.net' "$sshConfigPath" \
                    || { echo "registry: ssh Host block missing"; cat "$sshConfigPath"; exit 1; }
                  grep -q '"host-sample-host"' "$knownHostsPath" \
                    || { echo "registry: host known-hosts entry missing"; cat "$knownHostsPath"; exit 1; }
                  grep -q '"builder-sample-external"' "$knownHostsPath" \
                    || { echo "registry: external builder known-hosts entry missing"; cat "$knownHostsPath"; exit 1; }
                  cat "$machinesPath" > "$out"
                '';
          };
      };
    };
in
{
  flake.flakeModules.registry = registryModule;

  imports = [ registryModule ];
}
