# The fleet feature: one published flakeModule composing the typed schema,
# the canonical inventory, validation, and CI artifact derivation. nix-fleet
# exposes facts + pure projections; there is no NixOS module published here
# and no cross-class realization — a consumer's own flake-level module closes
# over its config.fleet and calls resolveBuildProfile (docs/contracts/
# builders.md carries the ~15-line wiring pattern).
{
  lib,
  config,
  ...
}:
let
  resolve = import ../../lib/build-profile.nix lib;
  serviceEndpoints = import ../../lib/service-endpoints.nix lib;

  # Named, fail-closed inventory validation, run by the render check so an
  # invalid canonical record fails `nix flake check` by name.
  validationErrors =
    fleet:
    lib.concatMap (
      hostId:
      let
        host = fleet.hosts.${hostId};
      in
      lib.optionals
        (((host.capabilities or { }).nixBuilder or { }).enable or false && (host.system or null) == null)
        [
          "fleet: host '${hostId}' has capabilities.nixBuilder.enable but no system — a builder must declare what it builds natively"
        ]
    ) (builtins.attrNames fleet.hosts)
    ++ lib.concatMap (
      extId:
      lib.optionals (fleet.externalBuilders.${extId}.publicHostKey == null) [
        "fleet: external builder '${extId}' has no publicHostKey — there is no host record to inherit trust from"
      ]
    ) (builtins.attrNames fleet.externalBuilders)
    ++ lib.concatMap (
      serviceId:
      lib.concatMap (
        endpointId:
        let
          endpoint = fleet.services.${serviceId}.endpoints.${endpointId};
          routeName = "fleet: service '${serviceId}' endpoint '${endpointId}'";
          tailnet = endpoint.tailnet or null;
          publicUrl = endpoint.publicUrl or null;
        in
        lib.optionals (tailnet == null && publicUrl == null) [
          "${routeName} has no route (tailnet or publicUrl required)"
        ]
        ++ lib.optionals (publicUrl == "") [ "${routeName} publicUrl must not be empty" ]
        ++ lib.optionals (tailnet != null && !(lib.hasPrefix "/" (tailnet.basePath or "/"))) [
          "${routeName} tailnet basePath must start with /"
        ]
        ++ lib.optionals (tailnet != null && !(builtins.hasAttr tailnet.host fleet.hosts)) [
          "${routeName} references unknown fleet host '${tailnet.host}'"
        ]
      ) (builtins.attrNames fleet.services.${serviceId}.endpoints)
    ) (builtins.attrNames fleet.services);

  assertRegistry =
    fleet:
    let
      errors = validationErrors fleet;
    in
    if errors == [ ] then true else throw (lib.head errors);

  # Renderer grammar check on sample data covering both member variants and
  # per-profile overrides; the real consumer-bound inventory is validated by
  # the same check.
  sample = {
    hosts.sample-nonbuilder = {
      system = null;
      tailscale.hostname = "fleet-peer";
      hostNames = [ "fleet-peer" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE1AAAAI-sample-peer";
      managementUser = null; # reach identity unset: sshConfig must omit User
    };
    hosts.sample-host = {
      system = "x86_64-linux";
      tailscale.hostname = "fleet-host";
      hostNames = [ "fleet-host" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE1AAAAI-sample";
      capabilities.nixBuilder = {
        enable = true;
        maxJobs = 1;
        supportedFeatures = [ "kvm" ];
      };
    };
    externalBuilders.sample-external = {
      uri = "ssh-ng://eu.nixbuild.net";
      systems = [ "aarch64-linux" ];
      publicHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI-sample-external";
    };
    services.sample-service.endpoints.api.tailnet = {
      host = "sample-host";
      port = 6280;
      basePath = "/mcp/";
    };
    services.sample-service.endpoints.public.publicUrl = "https://example.invalid/api/";
    buildProfiles.sample = {
      hosts.sample-host.maxJobs = 2;
      hosts.sample-host.supportedFeatures = [
        "big-parallel"
        "nixos-test"
      ];
      external.sample-external = {
        maxJobs = 4;
        sshUser = "root";
      };
    };
  };

  sampleSpecs = resolve.resolveBuildProfile sample "sample";

  rejects = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  serviceCheck =
    let
      endpoint = serviceEndpoints.resolveEndpoint sample {
        service = "sample-service";
        endpoint = "api";
        via = "tailnet";
      };
      missingRoute = sample // {
        services.sample-service.endpoints.api = { };
      };
      unknownHost = sample // {
        services.sample-service.endpoints.api.tailnet = {
          host = "absent-host";
          port = 6280;
        };
      };
      invalidPath = sample // {
        services.sample-service.endpoints.api.tailnet = {
          host = "sample-host";
          port = 6280;
          basePath = "mcp";
        };
      };
      select =
        fleet: service: endpointName: via:
        serviceEndpoints.resolveEndpoint fleet {
          inherit service via;
          endpoint = endpointName;
        };
      canonical = [
        [
          "omniroute"
          "api"
          "http://home-forge:20128"
          20128
          "home-forge"
        ]
        [
          "hindsight"
          "api"
          "http://home-forge:8888"
          8888
          "home-forge"
        ]
        [
          "docs-mcp"
          "mcp"
          "http://home-forge:6280/mcp"
          6280
          "home-forge"
        ]
        [
          "ntfy"
          "api"
          "http://la-admin-1:2586"
          2586
          "la-admin-1"
        ]
        [
          "niks3-write"
          "api"
          "http://oci-melb-1:5751"
          5751
          "oci-melb-1"
        ]
        [
          "bifrost"
          "embeddings"
          "http://oci-melb-1:7411/v1"
          7411
          "oci-melb-1"
        ]
        [
          "otel-collector"
          "otlp"
          "http://home-forge:4318"
          4318
          "home-forge"
        ]
        [
          "victoriametrics"
          "remote-write"
          "http://home-forge:8428/api/v1/write"
          8428
          "home-forge"
        ]
        [
          "victorialogs"
          "jsonline"
          "http://home-forge:9428/insert/jsonline"
          9428
          "home-forge"
        ]
      ];
    in
    endpoint.url == "http://fleet-host:6280/mcp/"
    && endpoint.host == "sample-host"
    && endpoint.hostname == "fleet-host"
    && endpoint.port == 6280
    &&
      serviceEndpoints.url sample {
        service = "sample-service";
        endpoint = "api";
        via = "tailnet";
      } == endpoint.url
    && builtins.all (
      entry:
      let
        result = select config.fleet (builtins.elemAt entry 0) (builtins.elemAt entry 1) "tailnet";
      in
      result.url == builtins.elemAt entry 2
      && result.port == builtins.elemAt entry 3
      && result.host == builtins.elemAt entry 4
    ) canonical
    &&
      select sample "sample-service" "public" "public" == {
        url = "https://example.invalid/api/";
        host = null;
        hostname = null;
        port = null;
      }
    && rejects (select sample "unknown-service" "api" "tailnet")
    && rejects (select sample "sample-service" "unknown-endpoint" "tailnet")
    && rejects (select unknownHost "sample-service" "api" "tailnet")
    && rejects (select sample "sample-service" "api" "public")
    && rejects (select sample "sample-service" "api" "other")
    && rejects (select missingRoute "sample-service" "api" "tailnet")
    && rejects (assertRegistry missingRoute)
    && rejects (assertRegistry unknownHost)
    && rejects (assertRegistry invalidPath);

  # The separation is load-bearing: the non-builder that resolveHosts accepts
  # must stay unreachable through the scheduling door. Forced by the render
  # check below (deepSeq in its attrset), so relaxing the capability check
  # fails `nix flake check` here instead of silently widening scheduling.
  schedulingRejection =
    let
      leak = {
        inherit (sample) hosts;
        externalBuilders = { };
        buildProfiles.trust-leak.hosts.sample-nonbuilder = { };
      };
    in
    !(builtins.tryEval (builtins.deepSeq (resolve.resolveBuildProfile leak "trust-leak") true)).success;

  fleetModule = {
    imports = [
      ./schema.nix
      ./inventory.nix
    ];
  };

  # nix-fleet's own check, not the published module's: a consumer would only
  # rebuild this fixture.
  renderCheck = {
    perSystem =
      { pkgs, ... }:
      {
        # Selector claims only: the pair contract is what catches a daemon
        # dialing a different endpoint than the option form advertises.
        checks.fleet-render =
          assert assertRegistry sample;
          assert assertRegistry config.fleet;
          assert schedulingRejection;
          assert serviceCheck;
          let
            specs = sampleSpecs;
            trustSpecs = resolve.resolveHosts sample {
              sample-nonbuilder = { };
              sample-host = { }; # scheduling specs render trust too
            };
          in
          pkgs.runCommand "fleet-render-check"
            rec {
              machines = resolve.machinesFile specs;
              sshConfig = resolve.sshConfig specs;
              knownHosts = builtins.toJSON (resolve.knownHosts trustSpecs);
              optionForm = builtins.toJSON (resolve.buildMachines specs);
              trustSshConfig = resolve.sshConfig trustSpecs;
              passAsFile = [
                "machines"
                "sshConfig"
                "knownHosts"
                "optionForm"
                "trustSshConfig"
              ];
            }
            ''
              grep -qx 'ssh-ng://nixbuild@fleet-host x86_64-linux - 2 1 big-parallel,nixos-test -' "$machinesPath" \
                || { echo "fleet: profile override did not reach the machines line"; cat "$machinesPath"; exit 1; }
              grep -qx 'ssh-ng://root@eu.nixbuild.net aarch64-linux - 4 1 - -' "$machinesPath" \
                || { echo "fleet: external builder line wrong"; cat "$machinesPath"; exit 1; }
              grep -qx '  User root' "$sshConfigPath" \
                || { echo "fleet: external sshUser override missing"; cat "$sshConfigPath"; exit 1; }

              ${pkgs.jq}/bin/jq -r '.[] | "\(.protocol)://\(.sshUser)@\(.hostName)"' "$optionFormPath" > option-form
              awk 'NF > 0 { print $1 }' "$machinesPath" > machines-form
              paste option-form machines-form | awk '$1 != $2 { print "fleet: option form says " $1 " but machines-file form says " $2; exit 1 }'

              for host in host-sample-host host-sample-nonbuilder; do
                grep -q "\"$host\"" "$knownHostsPath" \
                  || { echo "fleet: resolveHosts omitted $host"; cat "$knownHostsPath"; exit 1; }
              done
              # managementUser = null must not inherit the dispatch login.
              grep -q 'User' "$trustSshConfigPath" \
                && { echo "fleet: sshConfig emitted a User line for managementUser = null"; cat "$trustSshConfigPath"; exit 1; }

              cat "$machinesPath" > "$out"
            '';
      };
  };
in
{
  flake.flakeModules.fleet = fleetModule;

  flake.lib.buildProfile = resolve;
  flake.lib.serviceEndpoints = serviceEndpoints;

  imports = [
    fleetModule
    renderCheck
  ];
}
