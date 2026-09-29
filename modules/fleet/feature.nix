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
  telemetry = import ../../lib/telemetry.nix lib;

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
        ++
          lib.concatMap
            (
              direction:
              lib.optionals (
                (endpoint.telemetry or { }).${direction} or null != null
                && (endpoint.telemetry.${direction}.signals or [ ]) == [ ]
              ) [ "${routeName} telemetry.${direction}.signals must not be empty" ]
            )
            [
              "ingest"
              "sink"
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
    services.sample-collector.endpoints.http = {
      tailnet = {
        host = "sample-host";
        port = 4318;
      };
      telemetry.ingest = {
        protocol = "otlp-http";
        signals = [
          "traces"
          "logs"
        ];
      };
    };
    services.sample-collector.endpoints.grpc = {
      tailnet = {
        host = "sample-host";
        port = 4317;
      };
      telemetry.ingest = {
        protocol = "otlp-grpc";
        signals = [ "traces" ];
      };
    };
    services.sample-backend.endpoints.otlp = {
      tailnet = {
        host = "sample-host";
        port = 4319;
      };
      telemetry.sink = {
        protocol = "otlp-http";
        signals = [ "traces" ];
      };
    };
    services.sample-collector-second.endpoints.http = {
      tailnet = {
        host = "sample-nonbuilder";
        port = 4318;
      };
      telemetry.ingest = {
        protocol = "otlp-http";
        signals = [ "traces" ];
      };
    };
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

  telemetryCheck =
    let
      logs = telemetry.resolveIngest sample { signal = "logs"; };
      grpc = telemetry.resolveIngest sample {
        signal = "traces";
        protocol = "otlp-grpc";
      };
      chosen = telemetry.resolveIngest sample {
        signal = "traces";
        protocol = "otlp-http";
        collector = "sample-collector-second";
      };
      httpEnv = telemetry.otlpEnv {
        endpoint = logs;
        service = "example-app";
        hostId = "sample-host";
        extraAttributes."deployment.environment" = "test";
      };
      grpcEnv = telemetry.otlpEnv {
        endpoint = grpc;
        service = "example-app";
        hostId = "sample-host";
      };
      emptySignals = lib.recursiveUpdate sample {
        services.sample-collector.endpoints.http.telemetry.ingest.signals = [ ];
      };
      emptySinkSignals = lib.recursiveUpdate sample {
        services.sample-backend.endpoints.otlp.telemetry.sink.signals = [ ];
      };
      sinkOnly = sample // {
        services = {
          sample-backend = sample.services.sample-backend;
        };
      };
      sink = telemetry.resolveSink sample {
        service = "sample-backend";
        endpoint = "otlp";
        signal = "traces";
        protocol = "otlp-http";
      };
      evalSample =
        fleet:
        lib.evalModules {
          modules = [
            ./schema.nix
            { inherit fleet; }
          ];
        };
    in
    logs == {
      url = "http://fleet-host:4318";
      service = "sample-collector";
      hostname = "fleet-host";
      port = 4318;
      protocol = "otlp-http";
      signals = [
        "traces"
        "logs"
      ];
    }
    && chosen.url == "http://fleet-peer:4318"
    && chosen.service == "sample-collector-second"
    && grpc.url == "http://fleet-host:4317"
    && grpc.protocol == "otlp-grpc"
    && builtins.length (telemetry.ingestTargets sample { signal = "traces"; }) == 3
    && telemetry.ingestTargets sample { protocol = "otlp-grpc"; } == [ grpc ]
    &&
      sink == {
        url = "http://fleet-host:4319";
        service = "sample-backend";
        hostname = "fleet-host";
        port = 4319;
        protocol = "otlp-http";
        signals = [ "traces" ];
      }
    && telemetry.ingestTargets sinkOnly { signal = "traces"; } == [ ]
    && rejects (telemetry.resolveIngest sinkOnly { signal = "traces"; })
    && rejects (
      telemetry.resolveSink sample {
        service = "unknown";
        endpoint = "otlp";
      }
    )
    && rejects (
      telemetry.resolveSink sample {
        service = "sample-backend";
        endpoint = "unknown";
      }
    )
    && rejects (
      telemetry.resolveSink sample {
        service = "sample-collector";
        endpoint = "http";
      }
    )
    && rejects (
      telemetry.resolveSink sample {
        service = "sample-backend";
        endpoint = "otlp";
        signal = "logs";
      }
    )
    && rejects (
      telemetry.resolveSink sample {
        service = "sample-backend";
        endpoint = "otlp";
        protocol = "otlp-grpc";
      }
    )
    &&
      httpEnv == {
        OTEL_EXPORTER_OTLP_ENDPOINT = "http://fleet-host:4318";
        OTEL_EXPORTER_OTLP_PROTOCOL = "http/protobuf";
        OTEL_SERVICE_NAME = "example-app";
        OTEL_RESOURCE_ATTRIBUTES = "deployment.environment=test,host.name=sample-host,service.name=example-app";
      }
    &&
      grpcEnv == {
        OTEL_EXPORTER_OTLP_ENDPOINT = "http://fleet-host:4317";
        OTEL_EXPORTER_OTLP_PROTOCOL = "grpc";
        OTEL_SERVICE_NAME = "example-app";
        OTEL_RESOURCE_ATTRIBUTES = "host.name=sample-host,service.name=example-app";
      }
    && rejects (telemetry.resolveIngest sample { signal = "traces"; })
    && rejects (telemetry.resolveIngest sample { signal = "unknown"; })
    && rejects (telemetry.resolveIngest sample { signal = null; })
    && rejects (
      telemetry.resolveIngest sample {
        signal = "traces";
        protocol = "unknown";
      }
    )
    && rejects (
      telemetry.resolveIngest sample {
        signal = "traces";
        collector = "unknown";
      }
    )
    && rejects (
      telemetry.resolveIngest sample {
        signal = "traces";
        protocol = "otlp-grpc";
        collector = "sample-collector-second";
      }
    )
    && rejects (telemetry.resolveIngest sample { signal = "metrics"; })
    && rejects (
      telemetry.otlpEnv {
        endpoint = chosen // {
          protocol = "loki-push";
        };
        service = "example-app";
        hostId = "sample-host";
      }
    )
    &&
      (evalSample sample).config.fleet.services.sample-collector.endpoints.http.telemetry.ingest.signals
      == [
        "traces"
        "logs"
      ]
    && rejects (assertRegistry emptySignals)
    && rejects (assertRegistry emptySinkSignals)
    && rejects (evalSample emptySinkSignals)
      .config.fleet.services.sample-backend.endpoints.otlp.telemetry.sink.signals
    && rejects (evalSample emptySignals)
      .config.fleet.services.sample-collector.endpoints.http.telemetry.ingest.signals;

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

  ciArtifacts =
    { pkgs }:
    profileName:
    let
      specs = resolve.resolveBuildProfile config.fleet profileName;
    in
    assert resolve.assertNonEmpty profileName specs;
    pkgs.runCommand "ci-builders-${profileName}"
      rec {
        machines = resolve.machinesFile specs;
        sshConfig = resolve.sshConfig specs;
        knownHosts = builtins.toJSON (resolve.knownHosts specs);
        passAsFile = [
          "machines"
          "sshConfig"
          "knownHosts"
        ];
      }
      ''
        mkdir -p $out
        cp "$machinesPath" $out/machines
        cp "$sshConfigPath" $out/ssh_config
        # JSON entries -> /etc/ssh/ssh_known_hosts line format.
        ${pkgs.jq}/bin/jq -r 'to_entries[] | .value.hostNames[] as $n | "\($n) \(.value.publicKey)"' \
          "$knownHostsPath" > $out/known_hosts
      '';

  fleetModule = {
    imports = [
      ./schema.nix
      ./inventory.nix
    ];

    config = {
      perSystem =
        { pkgs, ... }:
        {
          checks.fleet-render =
            assert assertRegistry sample;
            assert assertRegistry config.fleet;
            assert schedulingRejection;
            assert serviceCheck;
            assert telemetryCheck;
            # Scheduling path (sampleSpecs) and trust path (trustSpecs) both
            # render here; the trust selection includes a NON-builder. The
            # separation itself is pinned by the schedulingRejection binding
            # below — if the capability check ever relaxes, eval fails there.
            let
              specs = sampleSpecs;
              trustSpecs = resolve.resolveHosts sample {
                sample-nonbuilder = { };
                sample-host = { }; # a BuilderSpec's host renders trust too
              };
            in
            pkgs.runCommand "fleet-render-check"
              rec {
                machines = resolve.machinesFile specs;
                sshConfig = resolve.sshConfig specs;
                knownHosts = builtins.toJSON (resolve.knownHosts specs);
                optionForm = builtins.toJSON (resolve.buildMachines specs);
                trustKnownHosts = builtins.toJSON (resolve.knownHosts trustSpecs);
                trustSshConfig = resolve.sshConfig trustSpecs;
                knownHostsText = resolve.knownHostsText trustSpecs;
                passAsFile = [
                  "machines"
                  "sshConfig"
                  "knownHosts"
                  "optionForm"
                  "trustKnownHosts"
                  "trustSshConfig"
                  "knownHostsText"
                ];
              }
              ''
                awk 'NF > 0 { if (NF != 7) { print "fleet: machines line has " NF " fields, expected 7"; exit 1 } }' "$machinesPath"
                grep -qx 'ssh-ng://nixbuild@fleet-host x86_64-linux - 2 1 big-parallel,nixos-test -' "$machinesPath" \
                  || { echo "fleet: fleet-host line wrong (override not applied?)"; cat "$machinesPath"; exit 1; }
                grep -qx 'ssh-ng://root@eu.nixbuild.net aarch64-linux - 4 1 - -' "$machinesPath" \
                  || { echo "fleet: external line wrong"; cat "$machinesPath"; exit 1; }
                grep -qx '  User root' "$sshConfigPath" \
                  || { echo "fleet: external sshUser override missing"; cat "$sshConfigPath"; exit 1; }

                # Nix-module form ≡ machines-file form. nixpkgs composes its
                # machines-file first field as protocol://sshUser@hostName from
                # the option form's separate fields; that has to equal the first
                # field the text renderer emits, or the two disagree about who
                # gets dialed.
                ${pkgs.jq}/bin/jq -r '.[] | "\(.protocol)://\(.sshUser)@\(.hostName)"' "$optionFormPath" > option-form
                awk 'NF > 0 { print $1 }' "$machinesPath" > machines-form
                paste option-form machines-form | awk '$1 != $2 { print "fleet: option form says " $1 " but machines-file form says " $2; exit 1 }'

                # Trust path: both selected hosts land, the non-builder included.
                grep -q '"host-sample-nonbuilder"' "$trustKnownHostsPath" \
                  || { echo "fleet: resolveHosts omitted the non-builder"; cat "$trustKnownHostsPath"; exit 1; }
                grep -q '"host-sample-host"' "$trustKnownHostsPath" \
                  || { echo "fleet: resolveHosts omitted the builder host"; cat "$trustKnownHostsPath"; exit 1; }
                # managementUser = null: no User line, never the dispatch default.
                grep -q 'User' "$trustSshConfigPath" \
                  && { echo "fleet: sshConfig emitted a User line for managementUser = null"; cat "$trustSshConfigPath"; exit 1; }
                grep -qx 'Host fleet-peer' "$trustSshConfigPath" \
                  || { echo "fleet: trust sshConfig missing the peer Host block"; cat "$trustSshConfigPath"; exit 1; }

                # Text-form ≡ option-form knownHosts: every attrset entry's
                # key must appear in the line form (same selection, same set).
                ${pkgs.jq}/bin/jq -r 'to_entries[] | .value.hostNames[0] + " " + .value.publicKey' "$trustKnownHostsPath" \
                  | while read -r line; do
                      grep -qx "$line" "$knownHostsTextPath" \
                        || { echo "fleet: knownHostsText missing line: $line"; exit 1; }
                    done

                cat "$machinesPath" > "$out"
              '';

          # CI builder bundles, one per declared build profile: machines file,
          # known-hosts (projection of the profile selection only), ssh client
          # config. The build-push-cache workflow installs these; the profile
          # name is the only selection the workflow makes.
          packages = builtins.mapAttrs (
            name: _: ciArtifacts { inherit pkgs; } name
          ) config.fleet.buildProfiles;
        };
    };
  };
in
{
  flake.flakeModules.fleet = fleetModule;

  flake.lib.buildProfile = resolve;
  flake.lib.serviceEndpoints = serviceEndpoints;
  flake.lib.telemetry = telemetry;

  # Self-application (dogfood): the published module's perSystem pieces (render
  # check, CI bundles) only land when the module is imported into this
  # evaluation too.
  imports = [ fleetModule ];
}
