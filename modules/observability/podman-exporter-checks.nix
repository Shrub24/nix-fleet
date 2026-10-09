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
in
{
  perSystem =
    { system, ... }:
    let
      pkgs = inputs.nixpkgs.legacyPackages.${system};
      inherit (import ../../lib/contract-leaf.nix { inherit lib pkgs; }) leaf;
      defaults = hostFor system { };
      override = hostFor system {
        services.podmanExporter.port = 19156;
        virtualisation.podman.autoPrune.enable = false;
      };
      package = pkgs.callPackage ../../pkgs/prometheus-podman-exporter/default.nix { };
      service = defaults.systemd.services.prometheus-podman-exporter;
    in
    {
      checks.podman-exporter-composition = leaf "podman-exporter-composition" [
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

      packages.prometheus-podman-exporter = package;
      # The guest is deliberately rootful: only inside this disposable VM does
      # the test get root. The sandbox host's Podman daemon/socket is never
      # shared. Build the fixture image into the guest store before starting it,
      # so the test does not need network access or a registry pull.
      checks.podman-exporter-vm = pkgs.testers.runNixOSTest {
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
            imageFile = pkgs.dockerTools.buildImage {
              name = "exporter-fixture";
              tag = "latest";
              copyToRoot = pkgs.buildEnv {
                name = "exporter-fixture-root";
                paths = [ pkgs.busybox ];
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
