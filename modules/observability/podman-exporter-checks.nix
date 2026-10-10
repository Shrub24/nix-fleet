# Podman producer checks: the authored service package/arguments, socket
# dependency, scrape join and port override. The integration boundary matters:
# nixpkgs' rootful `podman.socket` is `root:podman` and mode 0660, while the
# remote-mode exporter uses `CONTAINER_HOST` and a DynamicUser in that group.
# A rendered group name is not proof that the socket accepts a client; a
# disposable NixOS VM check exercises the rootful socket and a running container.
{
  lib,
  config,
  inputs,
  ...
}:
let
  aspects = config.flake.modules.nixos;

  # Both checks below assert architecture-independent claims, so they are
  # registered once on the canonical system. The composition leaf reads option
  # values, static unit settings and a predicate over a rendered service string —
  # all set unconditionally in the vendored module and in nixpkgs' Podman module
  # (`SupplementaryGroups`, `after`, `SocketGroup`). The VM check is
  # canonical-only twice over: it proves the same socket/container integration on
  # either architecture, and no aarch64 builder in the fleet advertises `kvm`.
  canonicalSystem = "x86_64-linux";
  canonicalPkgs = inputs.nixpkgs.legacyPackages.${canonicalSystem};

  inherit
    (import ../../lib/contract-leaf.nix {
      inherit lib;
      pkgs = canonicalPkgs;
    })
    leaf
    ;

  hostFor =
    system: extra:
    (lib.nixosSystem {
      inherit system;
      modules = [
        inputs.sops-nix.nixosModules.sops
        aspects.podman-exporter
        extra
        { system.stateVersion = "25.11"; }
        {
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "nodev";
            fsType = "tmpfs";
          };
        }
      ];
    }).config;
  # The composed hosts the composition leaf reads, on the canonical system.
  defaults = hostFor canonicalSystem { };
  override = hostFor canonicalSystem {
    services.podmanExporter.port = 19156;
    virtualisation.podman.autoPrune.enable = false;
  };
  service = defaults.systemd.services.prometheus-podman-exporter;
in
{
  # The packaged exporter is per-system by nature; the checks are not.
  perSystem =
    { system, ... }:
    {
      packages.prometheus-podman-exporter =
        inputs.nixpkgs.legacyPackages.${system}.callPackage
          ../../pkgs/prometheus-podman-exporter/default.nix
          { };
    };

  flake.checks.${canonicalSystem} = {
    podman-exporter-composition = leaf "podman-exporter-composition" [
      {
        message = "the Podman exporter listener and dormant scrape registration no longer agree, or the listener reached the firewall";
        ok =
          let
            cfg = defaults.services.podmanExporter;
            scrape = defaults.services.telemetry.scrape.podman;
          in
          cfg.listenAddress == "127.0.0.1"
          && scrape.target == cfg.listenAddress
          && scrape.port == cfg.port
          && service.serviceConfig.ExecStart != ""
          && !(builtins.elem cfg.port defaults.networking.firewall.allowedTCPPorts)
          && !(defaults.systemd.services ? vmagent);
      }
      {
        message = "a Podman exporter port override did not move the scrape registration with the listener";
        ok =
          override.services.podmanExporter.port == 19156
          && override.services.telemetry.scrape.podman.port == 19156;
      }
      {
        message = "the Podman exporter lost its rootful system socket dependency or effective group access wiring";
        ok =
          service.environment.CONTAINER_HOST == "unix:///run/podman/podman.sock"
          && builtins.elem "podman" service.serviceConfig.SupplementaryGroups
          && builtins.elem "podman.socket" service.after
          && defaults.virtualisation.podman.enable
          && defaults.systemd.sockets.podman.socketConfig.SocketGroup == "podman"
          && service.serviceConfig.DynamicUser;
      }
      {
        message = "the exporter enabled unrestricted container-label copying by default";
        ok = !(lib.hasInfix "--collector.store_labels" service.serviceConfig.ExecStart);
      }
      {
        message = "the exporter aspect stopped composing the existing Podman aspect's default policy";
        ok =
          override.virtualisation.podman.enable && override.services.telemetry.scrape.podman.port == 19156;
      }
    ];

    # The guest is deliberately rootful: only inside this disposable VM does the
    # test get root. The sandbox host's Podman daemon/socket is never shared. Build
    # the fixture image into the guest store before starting it, so the test does
    # not need network access or a registry pull.
    #
    # Registered on the canonical system only. What the check proves — the packaged
    # service reaches the rootful socket and a container's metrics appear — is the
    # same on either architecture, and no aarch64 builder in the fleet advertises
    # `kvm` (the aarch64 builders offer `big-parallel`, the x86_64 ones `kvm` and
    # `nixos-test`), so a per-system copy could never be built or cached and would
    # fail the fleet build on every dispatch.
    podman-exporter-vm = canonicalPkgs.testers.runNixOSTest {
      name = "podman-exporter-rootful-socket";
      nodes.machine = { ... }: {
        imports = [ aspects.podman-exporter ];
        virtualisation.podman.enable = true;
        virtualisation.memorySize = 2048;
        virtualisation.diskSize = 4096;
        virtualisation.oci-containers.backend = "podman";
        system.stateVersion = "25.11";
        virtualisation.oci-containers.containers.exporter-fixture = {
          image = "exporter-fixture:latest";
          imageFile = canonicalPkgs.dockerTools.buildImage {
            name = "exporter-fixture";
            tag = "latest";
            copyToRoot = canonicalPkgs.buildEnv {
              name = "exporter-fixture-root";
              paths = [ canonicalPkgs.busybox ];
              pathsToLink = [ "/bin" ];
            };
            config.Cmd = [
              "sleep"
              "600"
            ];
          };
        };
      };
      testScript = ''
        machine.start()
        machine.wait_for_unit("podman.socket")
        machine.wait_for_unit("prometheus-podman-exporter.service")
        machine.wait_for_unit("podman-exporter-fixture.service")
        machine.wait_until_succeeds("curl -fsS http://127.0.0.1:9156/metrics | grep '^podman_container_info'")
        machine.succeed("curl -fsS http://127.0.0.1:9156/metrics | grep 'exporter-fixture'")
      '';
    };
  };
}
