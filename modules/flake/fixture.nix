# Fixture evaluation class: exercises every aspect on throwaway NixOS targets,
# consumer-shaped — imports the upstream modules aspects expect and binds
# obviously-fake placeholders. Never activated, never decrypts anything. One
# fixture per declared system: the wiring module builds each toplevel as a
# check, so platform-specific packaging (python3, apprise) is exercised for
# every architecture the fleet actually runs. The host asserts only what it can
# read from its own configuration; every throwaway contract evaluation lives in
# its own leaf check (`contractLeaves` below), so forcing the host stays cheap.
{
  lib,
  config,
  inputs,
  ...
}:
let
  # Stand-in for a consumer's SOPS files: an existing YAML placeholder in the
  # flake source, so the existence gates and sops-nix's manifest validation
  # pass without committing any real secret material.
  fixtureSecretFile = ./. + "/fixture-secrets.yaml";

  # Placeholder age key path. sops-nix requires a configured key source and
  # rejects store paths for it; nothing here is ever activated, so this file
  # never has to exist.
  fixtureAgeKeyFile = "/run/secrets/fixture-age-key";

  # Every throwaway NixOS evaluation has an explicit state version so tests
  # stay warning-free and do not inherit a changing nixpkgs default.
  fixtureNixosSystem =
    args:
    lib.nixosSystem (
      args
      // {
        modules = [ { system.stateVersion = "25.11"; } ] ++ args.modules;
      }
    );

  aspects = config.flake.modules.nixos;

  # The v2 consumer wiring, exercised for real: a flake-level module closes
  # over this evaluation's merged config.fleet, resolves the profile through
  # the public API, and passes the projection into the NixOS module as args.
  # This is exactly the ~15-line pattern docs/contracts/builders.md prescribes.
  resolve = import ../../lib/build-profile.nix lib;
  resolvedProfile = resolve.resolveBuildProfile config.fleet "fixture";

  # The CI cache coordinate the build-push-cache workflow defaults to must be
  # derived from the contract, not a literal that happens to match it: the
  # mutation moves the record and the resolved URL has to move with it.
  cacheApiUrl = config.flake.lib.serviceEndpoints.cacheApiUrl config.fleet;
  cacheApiUrlMutated = config.flake.lib.serviceEndpoints.cacheApiUrl (
    lib.recursiveUpdate config.fleet {
      services."niks3-write".endpoints.api.tailnet.port = 5752;
    }
  );

  # A throwaway telemetry host for the caller's system. The contract
  # evaluations below assert on its rendered config, so they are evaluated for
  # the system of the check that carries them.
  telemetryHostFor =
    system: imports: telemetryConfig:
    (fixtureNixosSystem {
      inherit system;
      modules = [
        inputs.sops-nix.nixosModules.sops
      ]
      ++ imports
      ++ [ { services.telemetry = telemetryConfig; } ];
    }).config;
  vmagentHostFor =
    system: telemetryConfig: telemetryHostFor system [ aspects.telemetry-vmagent ] telemetryConfig;

  # The credential guard the vmagent unit runs, taken from the unit's own
  # rendered ExecStartPre rather than re-derived here, so the check that builds
  # it runs the artifact that ships. Evaluated for the checking system because
  # the script embeds the coreutils path it calls.
  guardScriptFor =
    system:
    let
      pre =
        (vmagentHostFor system {
          scrape.app = {
            target = "127.0.0.1";
            port = 9187;
          };
          destinations.metrics = {
            protocol = "prometheus-remote-write";
            endpoint = "https://metrics.invalid/api/v1/write";
            signals = [ "metrics" ];
            headers.Authorization = {
              secret = "token";
              prefix = "Bearer ";
            };
          };
          secretFiles.token = fixtureSecretFile;
          secretKeys.token = "fixture/token";
        }).systemd.services.vmagent.serviceConfig.ExecStartPre;
    in
    lib.head (lib.splitString " " (lib.head pre));

  # The contract evaluations behind the fixture's leaf checks: throwaway
  # evaluations, independent of the fixture host, parameterized by the system of
  # the check that carries them. Splitting them out of the host's assertions is
  # what keeps the host's own evaluation cheap.
  # The retained contract leaves are fixture-wide consumer checks.
  contractLeaves =
    system:
    let

      # A throwaway host for the cases whose subject is a refusal: minimal, so the
      # only assertions it can carry are the ones under test.
      admissionEval =
        modules:
        fixtureNixosSystem {
          inherit system;
          modules = [
            inputs.sops-nix.nixosModules.sops
            {
              boot.loader.grub.enable = false;
              fileSystems."/" = {
                device = "nodev";
                fsType = "tmpfs";
              };
              system.stateVersion = "25.11";
            }
          ]
          ++ modules;
        };
      admissionFailures =
        modules:
        map (assertion: assertion.message) (
          builtins.filter (assertion: !assertion.assertion) (admissionEval modules).config.assertions
        );
      buildAccountTrustChecks =
        let
          evaluated =
            modules:
            (fixtureNixosSystem {
              inherit system;
              inherit modules;
            }).config;
          renamed = evaluated [
            aspects.build-account
            {
              services.build-account.name = "dispatcher";
              nix.settings.trusted-users = [ "existing-coordinator" ];
            }
          ];
        in
        # The dispatch identity the consumer declares is what has to be trusted,
        # and the consumer's own entry survives the merge. The default name and
        # nixpkgs' `root` entry are the aspect's own literal and the platform's
        # baseline, not claims about a consumer's host.
        lib.elem renamed.services.build-account.name renamed.nix.settings.trusted-users
        && lib.elem "existing-coordinator" renamed.nix.settings.trusted-users;

      tailscaleAutoconnectChecks =
        let
          units =
            extra:
            (fixtureNixosSystem {
              inherit system;
              modules = [
                inputs.sops-nix.nixosModules.sops
                aspects.tailscale
                extra
              ];
            }).config.systemd.units;
          unbound = units { };
          bound = units { services.tailscale.secretFiles.auth = ./fixture.nix; };
        in
        # Unbound, no autoconnect unit exists at all; a unit holding only the
        # ordering drop-in has no ExecStart and warns on every boot. Bound, the
        # unit carries nixpkgs' script and the sops ordering together.
        !(unbound ? "tailscaled-autoconnect.service")
        && lib.hasInfix "ExecStart=" bound."tailscaled-autoconnect.service".text
        && lib.hasInfix "sops-install-secrets.service" bound."tailscaled-autoconnect.service".text;

      nixGcChecks =
        let
          evaluated =
            extra:
            (fixtureNixosSystem {
              inherit system;
              modules = [
                inputs.sops-nix.nixosModules.sops
                aspects.nix-gc
                # The notify aspect owns the fail-closed rule this leaf tests: a
                # registration may only name a unit with a real service.
                aspects.notify
                extra
              ];
            }).config;
          defaults = evaluated { };
          # Every unit off at once: the update that removes the schedule. The
          # checks below read what the composition produced — rendered units and
          # the registration set — because an override that only sets option
          # values cannot show a registration that outlived its unit.
          disabled = evaluated {
            programs.nh.clean.enable = false;
            services.fast-nix-gc.enable = false;
            services.fast-nix-optimise.enable = false;
          };
          # One flag off while the others stay on: the shape a consumer override
          # actually takes, and the only case that discriminates a registration
          # wired to a sibling's flag — with every flag off, a mis-wired
          # registration is absent for the wrong reason and passes.
          optimiseOff = evaluated { services.fast-nix-optimise.enable = false; };
        in
        # Every unit the aspect owns registers its own failure. The schedules,
        # weights and package the units carry are the aspect's own defaults on
        # the upstream options, restated in `modules/maintenance/nix-gc.nix`.
        (defaults.services.notify.events ? "nh-clean")
        && (defaults.services.notify.events ? "fast-nix-gc")
        && (defaults.services.notify.events ? "fast-nix-optimise")
        # Turning a unit off is the override the contract invites, so it must
        # leave no trace. Two defects this catches: a registration left behind
        # with no unit to attach to, and the ordering drop-in on its own, which
        # renders a phantom `nh-clean` with no ExecStart (the same failure class
        # as the unconditional `tailscaled-autoconnect`).
        && !(disabled.systemd.units ? "nh-clean.service")
        && !(disabled.services.notify.events ? "nh-clean")
        && !(disabled.services.notify.events ? "fast-nix-gc")
        && !(disabled.services.notify.events ? "fast-nix-optimise")
        # One flag off, the others on: only that unit's registration goes. A
        # registration wired to a sibling's flag survives the all-off case and
        # fails here.
        && !(optimiseOff.systemd.units ? "fast-nix-optimise.service")
        && !(optimiseOff.services.notify.events ? "fast-nix-optimise")
        && (optimiseOff.services.notify.events ? "nh-clean")
        && (optimiseOff.services.notify.events ? "fast-nix-gc")
        # The symptom in notify's own words, so this leaf fails the way a
        # consumer's build did.
        && !(lib.any (
          assertion:
          !assertion.assertion && lib.hasInfix "has no systemd service implementation" assertion.message
        ) disabled.assertions);

      nodeExporterIdentityChecks =
        # The label is consumer-owned: a value the consumer declares wins over
        # the label the aspect derives from the host name and the bound port. The
        # derived label is read off the fixture host's composed registration,
        # which couples it to the exporter's own bind.
        (fixtureNixosSystem {
          inherit system;
          modules = [
            aspects.node-exporter
            {
              networking.hostName = "other-probe";
              services.telemetry.scrape.node.labels.instance = "consumer-owned";
            }
          ];
        }).config.services.telemetry.scrape.node.labels.instance == "consumer-owned";

      # The alerting aspect's own contract: an enabled vmalert instance without a
      # datasource, a notifier or a management bind is refused by name, per
      # instance. The unbound composition is the aspect's own default, and the
      # bound instance's registration is the host's alerting→notify seam.
      alertingAdmissionChecks =
        builtins.any (lib.hasPrefix "vmalert: instance(s) 'unbound-notifier'") (admissionFailures [
          aspects.vmalert
          {
            services.vmalert.instances.unbound-notifier = {
              enable = true;
              settings."datasource.url" = "http://127.0.0.1:8428";
            };
          }
        ])
        && builtins.any (lib.hasPrefix "vmalert: instance(s) 'unbound-datasource'") (admissionFailures [
          aspects.vmalert
          { services.vmalert.instances.unbound-datasource.enable = true; }
        ])
        && builtins.any (lib.hasPrefix "vmalert: instance(s) 'unbound-management'") (admissionFailures [
          aspects.vmalert
          {
            services.vmalert.instances.unbound-management = {
              enable = true;
              settings = {
                "datasource.url" = "http://127.0.0.1:8428";
                "notifier.url" = [ "http://127.0.0.1:9093" ];
              };
            };
          }
        ]);
      # The substitution catalog is a fleet-owned baseline, not an option surface:
      # a consumer appends through nix.conf's own extra-substituters key, or
      # replaces the list outright with mkForce. Both seams are exercised here so
      # neither can rot into an option nothing renders again.
      nixBaselineSubstitutionSeams =
        let
          settingsFor =
            extra:
            (admissionEval [
              aspects.nix-baseline
              extra
            ]).config.nix.settings;
          base = settingsFor { };
          appended = settingsFor {
            nix.settings."extra-substituters" = [ "https://appended.invalid" ];
            nix.settings."extra-trusted-public-keys" = [ "appended.invalid-1:AAAA" ];
          };
          replaced = settingsFor {
            nix.settings.substituters = lib.mkForce [ "https://replaced.invalid" ];
          };
        in
        # Appending is a key of its own, so the baseline list and the baseline's
        # own keys must survive it; replacing is explicit and drops the baseline
        # entries rather than unioning them with it. The catalog's contents are
        # fleet data owned by `modules/system/nix-baseline.nix`.
        appended.substituters == base.substituters
        && appended."trusted-public-keys" == base."trusted-public-keys"
        && appended."extra-substituters" == [ "https://appended.invalid" ]
        && appended."extra-trusted-public-keys" == [ "appended.invalid-1:AAAA" ]
        && replaced.substituters == [ "https://replaced.invalid" ];
    in
    {
      # One named leaf per contract evaluation, each carried by its own check so
      # the fixture host above never forces it. A leaf that fails throws the
      # named error at evaluation, which is why every message reads as the
      # contract that broke rather than as a generic check failure.
      build-account-trust = {
        message = "build-account: dispatch trust, account renaming or trusted-user merging regressed";
        ok = buildAccountTrustChecks;
      };
      tailscale-autoconnect = {
        message = "tailscale: the autoconnect unit is rendered without an auth key, or lost its ordering";
        ok = tailscaleAutoconnectChecks;
      };
      nix-baseline-substitution = {
        message = "nix-baseline: the append or mkForce-replace seam of the substitution catalog regressed";
        ok = nixBaselineSubstitutionSeams;
      };
      nix-gc-defaults = {
        message = "nix-gc: a unit's failure registration no longer follows its enable flag, or turning the units off left a trace";
        ok = nixGcChecks;
      };
      alerting-admission = {
        message = "alerting: vmalert no longer refuses an enabled instance without a datasource, a notifier or a management bind, by name and per instance";
        ok = alertingAdmissionChecks;
      };
      node-exporter-identity = {
        message = "node-exporter: a consumer's scrape instance label no longer wins over the aspect's own derivation";
        ok = nodeExporterIdentityChecks;
      };
    };

  fixtureModule =
    {
      config,
      resolvedProfile,
      ...
    }:
    {
      imports = [
        inputs.sops-nix.nixosModules.sops
        inputs.niks3.nixosModules.niks3
      ]
      ++ (with aspects; [
        alertmanager
        beszel-agent
        bifrost
        build-account
        nix-baseline
        nix-gc
        node-exporter
        podman
        niks3-cache
        niks3-publisher
        notify
        ssh
        tailscale
        mosh
        telemetry
        telemetry-metrics
        telemetry-logs
        telemetry-otlp
        telemetry-vector
        telemetry-vmagent
        telemetry-otel-collector-otlp
        vmalert
      ]);

      boot.loader.grub.enable = false;
      fileSystems."/" = {
        device = "nodev";
        fsType = "tmpfs";
      };
      system.stateVersion = "25.11";

      sops.age.keyFile = fixtureAgeKeyFile;

      # Composition guard: only emergent cross-aspect properties belong here —
      # a claim no single aspect owns and that plain option evaluation cannot
      # falsify. Restating an aspect's own literal is owned by that aspect.
      assertions = [
        {
          # Emergent property of the consumer wiring: the projection the
          # flake-level API returns is what this host rendered. What the
          # projection contains is the fleet-render check's claim.
          assertion = config.nix.buildMachines != [ ] && config.programs.ssh.knownHosts != { };
          message = "fixture: the consumer build-profile wiring reached no build machine or known host.";
        }
        {
          assertion =
            cacheApiUrl == "http://oci-melb-1:5751" && cacheApiUrlMutated == "http://oci-melb-1:5752";
          message = "fixture: the CI cache URL is not derived from the niks3-write record.";
        }
        {
          assertion =
            config.systemd.services.fixture-monitored.onFailure == [ "notify-event@fixture-monitored.service" ];
          message = "fixture: the notification aspect attached no native failure hook for a registered unit.";
        }
        {
          # The guard must cover the unit nixpkgs actually creates — including
          # a container that renamed it.
          assertion =
            config.systemd.services."podman-fixture-container".startLimitIntervalSec == 3600
            && config.systemd.services."podman-fixture-container".startLimitBurst == 5
            && config.systemd.services."fixture-custom-name".startLimitIntervalSec == 3600;
          message = "fixture: the podman-baseline guard did not cover the container units.";
        }
        {
          assertion =
            let
              collector = config.services.opentelemetry-collector;
              telemetry = config.services.telemetry;
              inherit (collector) settings;
            in
            collector.enable
            && settings.receivers.otlp.protocols.grpc.endpoint == "127.0.0.1:4317"
            && settings.receivers.otlp.protocols.http.endpoint == "127.0.0.1:4318"
            && settings.exporters."otlphttp/secure".headers.Authorization == "Bearer \${env:OTELCOL_token}"
            && settings.exporters."otlp/plain".tls.insecure
            &&
              settings.exporters."prometheusremotewrite/victoria".endpoint
              == "http://metrics.invalid/api/v1/write"
            &&
              settings.exporters."prometheusremotewrite/archive".headers.Authorization
              == "Bearer \${env:OTELCOL_metricsToken}"
            && telemetry.destinations.secure.protocol == "otlp-http"
            && telemetry.destinations.secure.signals == [ "traces" ]
            &&
              telemetry.destinations.plain.signals == [
                "traces"
                "metrics"
                "logs"
              ]
            && telemetry.destinations.victoria.signals == [ "metrics" ]
            &&
              settings.service.pipelines.traces.exporters == [
                "otlp/plain"
                "otlphttp/secure"
              ]
            # A traces-only backend (the initial LLM-observability deployment)
            # receives neither metrics nor logs from the default fanout; the
            # metrics fanout is an explicit selection of the remote-write stores
            # only, so the OTLP gateway that also accepts metrics receives none.
            &&
              settings.service.pipelines.metrics.exporters == [
                "prometheusremotewrite/victoria"
                "prometheusremotewrite/archive"
              ]
            && settings.service.pipelines.logs.exporters == [ "otlp/plain" ]
            && !(builtins.elem "otlphttp/secure" settings.service.pipelines.metrics.exporters)
            && !(builtins.elem "otlphttp/secure" settings.service.pipelines.logs.exporters)
            && !(builtins.elem "otlp/plain" settings.service.pipelines.metrics.exporters)
            && !(builtins.elem "prometheusremotewrite/victoria" settings.service.pipelines.traces.exporters)
            # No standalone pre-export batch processor: acceptance commits to
            # the exporter's own persistent queue instead of to a volatile
            # batch stage.
            && !(settings.processors ? batch)
            && !(builtins.elem "batch" settings.service.pipelines.traces.processors)
            &&
              settings.service.pipelines.traces.processors == [
                "memory_limiter"
                "resource"
                "attributes"
              ]
            &&
              settings.processors.resource.attributes == [
                {
                  key = "host.name";
                  value = "fixture-host";
                  action = "upsert";
                }
              ]
            # Persistent delivery: one exporterhelper queue per OTLP exporter,
            # fsync'd file storage under the unit's state directory, a finite
            # serialized-payload capacity and indefinite retry — never the
            # unsupported (in the pin) file_storage database cap.
            # The production queue path is only durable because it is the unit's
            # own StateDirectory, and DynamicUser is what makes it writable
            # without an owner. Assert the coupling, not the literal against
            # itself: a nixpkgs StateDirectory change must fail here rather than
            # leave every offline check green over a queue that cannot persist.
            &&
              settings.extensions.file_storage.directory
              == "/var/lib/${config.systemd.services.opentelemetry-collector.serviceConfig.StateDirectory}/queue"
            && config.systemd.services.opentelemetry-collector.serviceConfig.DynamicUser
            && settings.extensions.file_storage.fsync
            && settings.extensions.file_storage.create_directory
            && settings.extensions.file_storage.directory_permissions == "0700"
            && settings.extensions.file_storage.compaction.on_start
            && settings.extensions.file_storage.compaction.on_rebound
            && !(settings.extensions.file_storage ? max_size)
            && settings.service.extensions == [ "file_storage" ]
            &&
              builtins.all
                (
                  exporter:
                  exporter.sending_queue.sizer == "bytes"
                  && exporter.sending_queue.queue_size == 268435456
                  && exporter.sending_queue.storage == "file_storage"
                  && exporter.sending_queue.block_on_overflow == false
                  && exporter.sending_queue.batch == { }
                  && exporter.retry_on_failure.max_elapsed_time == 0
                )
                [
                  settings.exporters."otlphttp/secure"
                  settings.exporters."otlp/plain"
                ]
            # The Prometheus remote-write exporter rejects `sending_queue` in
            # Collector Contrib 0.155.0, so it persists through its own WAL and
            # keeps its finite queue there.
            && !(settings.exporters."prometheusremotewrite/victoria" ? sending_queue)
            &&
              lib.hasPrefix settings.extensions.file_storage.directory
                settings.exporters."prometheusremotewrite/victoria".wal.directory
            &&
              settings.exporters."prometheusremotewrite/victoria".wal.directory
              == "/var/lib/opentelemetry-collector/queue/wal-victoria"
            && settings.exporters."prometheusremotewrite/victoria".remote_write_queue.enabled
            && settings.exporters."prometheusremotewrite/victoria".retry_on_failure.max_elapsed_time == 0
            # Delivery health: explicit loopback metrics, never the implicit
            # port 8888 listener.
            &&
              settings.service.telemetry.metrics.readers == [
                {
                  pull.exporter.prometheus = {
                    host = "127.0.0.1";
                    port = 9464;
                  };
                }
              ]
            && !(settings.service.telemetry.metrics ? address)
            && !(builtins.elem 8888 config.networking.firewall.allowedTCPPorts)
            && !(builtins.elem 9464 config.networking.firewall.allowedTCPPorts)
            # The additional network ingress is a distinct receiver feeding the
            # same exporter IDs, with source-specific pipelines: local
            # enrichment never relabels forwarded telemetry.
            && settings.receivers."otlp/ingress".protocols.http.endpoint == "100.64.0.9:4318"
            && !(settings.receivers."otlp/ingress".protocols ? grpc)
            && telemetry.otlp.httpUrl == "http://127.0.0.1:4318"
            && telemetry.otlp.grpcUrl == "http://127.0.0.1:4317"
            && settings.service.pipelines."traces/ingress".receivers == [ "otlp/ingress" ]
            &&
              settings.service.pipelines."traces/ingress".exporters == settings.service.pipelines.traces.exporters
            && !(builtins.elem "resource" settings.service.pipelines."traces/ingress".processors)
            && builtins.elem "resource" settings.service.pipelines.traces.processors
            && settings.service.pipelines."metrics/ingress".receivers == [ "otlp/ingress" ]
            && settings.service.pipelines."logs/ingress".receivers == [ "otlp/ingress" ]
            && !(config.systemd.services ? "otlp-ingress");
          message = "fixture: the rendered telemetry receiver, exporter, processor, pipeline or ingress set regressed.";
        }
        {
          # The host-local contract: the OTLP endpoint producers read must be
          # the receiver the collector actually binds, and the collector serves
          # only the inputs it was composed for — the metrics lane's scrape
          # realization owns scraping, so this collector has no prometheus
          # receiver and no `metrics/scrape` pipeline.
          assertion =
            let
              otlp = config.services.telemetry.otlp;
              settings = config.services.opentelemetry-collector.settings;
            in
            otlp.httpUrl == "http://127.0.0.1:4318"
            && otlp.grpcUrl == "http://127.0.0.1:4317"
            # The declared ingress address is what the additional listener binds,
            # while the producer endpoints above stay loopback. Asserting the
            # address as an input would restate the fixture's own module argument;
            # asserting the listener it produces is the coupling.
            && lib.hasPrefix "${otlp.ingress.host}:" settings.receivers."otlp/ingress".protocols.http.endpoint
            && settings.receivers.otlp.protocols.http.endpoint == "${otlp.host}:${toString otlp.httpPort}"
            && settings.receivers.otlp.protocols.grpc.endpoint == "${otlp.host}:${toString otlp.grpcPort}"
            # Configuring network ingress does not move the local producer
            # endpoints: they stay loopback, and the extra listener is separate.
            && lib.hasPrefix "http://127.0.0.1:" otlp.httpUrl
            && lib.hasPrefix "http://127.0.0.1:" otlp.grpcUrl
            && !(settings.receivers ? prometheus)
            && settings.service.pipelines.metrics.receivers == [ "otlp" ]
            && settings.service.pipelines.traces.receivers == [ "otlp" ]
            && settings.service.pipelines.logs.receivers == [ "otlp" ]
            &&
              builtins.attrNames settings.service.pipelines == [
                "logs"
                "logs/ingress"
                "metrics"
                "metrics/ingress"
                "traces"
                "traces/ingress"
              ];
          message = "fixture: the telemetry scrape registration, local OTLP endpoint, or composed pipeline contract regressed.";
        }
        {
          # The vmagent realization owns its unit: every registered job in
          # its config, a bounded persistent queue, a loopback management
          # endpoint, and the credential binding its remote-write headers need.
          assertion =
            let
              vmagent = config.services.vmagent;
              unit = config.systemd.services.vmagent;
            in
            vmagent.enable
            # The build-time `-dryRun` check validates this YAML with the real
            # binary; keeping it on is what makes a malformed registration a
            # build failure.
            && vmagent.checkConfig
            &&
              vmagent.prometheusConfig.scrape_configs == [
                {
                  job_name = "fixture-app";
                  metrics_path = "/metrics";
                  scheme = "http";
                  scrape_interval = "30s";
                  static_configs = [
                    {
                      targets = [ "127.0.0.1:9187" ];
                      labels.service = "fixture-app";
                    }
                  ];
                }
                {
                  job_name = "fixture-sidecar";
                  metrics_path = "/metrics/extra";
                  scheme = "http";
                  scrape_interval = "15s";
                  static_configs = [
                    {
                      targets = [ "127.0.0.1:9101" ];
                      labels = { };
                    }
                  ];
                }
                {
                  # Contributed by the node-exporter aspect, which also owns
                  # the listener this target names.
                  job_name = "node";
                  metrics_path = "/metrics";
                  scheme = "http";
                  scrape_interval = "30s";
                  static_configs = [
                    {
                      targets = [ "127.0.0.1:9100" ];
                      labels.instance = "${config.networking.hostName}:9100";
                    }
                  ];
                }
                {
                  # The collector's own delivery-health endpoint, registered
                  # through the ordinary producer interface: exposing those
                  # metrics here starts no second provider — the collector owns
                  # no scraper and the target is the listener nixpkgs' unit
                  # binds.
                  job_name = "otel-collector-health";
                  metrics_path = "/metrics";
                  scheme = "http";
                  scrape_interval = "30s";
                  static_configs = [
                    {
                      targets = [ "127.0.0.1:9464" ];
                      labels.instance = "${config.networking.hostName}:otel-collector";
                    }
                  ];
                }
                {
                  # The Vector provider's loopback health listener, registered
                  # by the provider that binds it. The target is the
                  # prometheus_exporter sink below, which carries only Vector's
                  # own internal metrics.
                  job_name = "vector-health";
                  metrics_path = "/metrics";
                  scheme = "http";
                  scrape_interval = "30s";
                  static_configs = [
                    {
                      targets = [ "127.0.0.1:9598" ];
                      labels.instance = "${config.networking.hostName}:vector";
                    }
                  ];
                }
                {
                  # vmagent's own loopback management endpoint, registered the
                  # same way: the selected scrape provider collects its own
                  # backlog and send-error metrics.
                  job_name = "vmagent-health";
                  metrics_path = "/metrics";
                  scheme = "http";
                  scrape_interval = "30s";
                  static_configs = [
                    {
                      targets = [ "127.0.0.1:8429" ];
                      labels.instance = "${config.networking.hostName}:vmagent";
                    }
                  ];
                }
              ]
            &&
              (builtins.elemAt config.services.opentelemetry-collector.settings.service.telemetry.metrics.readers 0)
              .pull.exporter.prometheus.port == config.services.telemetry.scrape.otel-collector-health.port
            && !(config.services.opentelemetry-collector.settings.receivers ? prometheus)
            # One remote-write target per selected metrics destination, in
            # pipeline order: URL, then the shared queue path and loopback
            # listen, then the per-destination disk bound and headers (the
            # empty entry is the headerless destination's slot).
            &&
              vmagent.extraArgs == [
                "-remoteWrite.url=http://metrics.invalid/api/v1/write"
                "-remoteWrite.url=https://archive.invalid/api/v1/write"
                "-remoteWrite.tmpDataPath=%S/vmagent/remote_write_tmp"
                "-httpListenAddr=127.0.0.1:8429"
                "-remoteWrite.maxDiskUsagePerURL=1073741824"
                "-remoteWrite.maxDiskUsagePerURL=1073741824"
                "-remoteWrite.headers="
                "-remoteWrite.headers=Authorization: Bearer %{VMAGENT_metricsToken}"
              ]
            && unit.serviceConfig.StateDirectory == "vmagent"
            && lib.hasInfix "-httpListenAddr=127.0.0.1:8429" unit.serviceConfig.ExecStart
            && lib.hasInfix "-remoteWrite.tmpDataPath=%S/vmagent/remote_write_tmp" unit.serviceConfig.ExecStart
            && !vmagent.openFirewall
            && !(builtins.elem 8429 config.networking.firewall.allowedTCPPorts)
            && config.services.notify.events.vmagent.failure != null
            && unit.onFailure != [ ]
            # Only the destination that actually carries a header binds a
            # secret; the credential reaches the unit through the environment,
            # never through the store or the command line.
            && config.sops.secrets."vmagent/metricsToken".sopsFile == fixtureSecretFile
            && config.sops.secrets."vmagent/metricsToken".key == "metrics/token"
            && builtins.elem "vmagent.service" config.sops.secrets."vmagent/metricsToken".restartUnits
            && builtins.elem "vmagent.service" config.sops.templates."vmagent.env".restartUnits
            &&
              config.sops.templates."vmagent.env".content
              == "VMAGENT_metricsToken=${config.sops.placeholder."vmagent/metricsToken"}\n"
            && unit.serviceConfig.EnvironmentFile == [ config.sops.templates."vmagent.env".path ]
            # The credential only becomes readable at unit start, so the guard
            # runs there, before vmagent parses the argument array it indexes
            # headers into.
            && builtins.length unit.serviceConfig.ExecStartPre == 1
            && lib.hasInfix "VMAGENT_metricsToken" (builtins.head unit.serviceConfig.ExecStartPre);
          message = "fixture: the vmagent scrape provider's rendered jobs, bounded queue, loopback listen, credential binding, or notify ownership regressed.";
        }
        {
          # The node-exporter aspect owns the exporter, the loopback bind and
          # its own scrape registration, so the registration has to track
          # whatever this host binds — nixpkgs renders the listen address, the
          # aspect names the target — and the bound port stays off the firewall.
          # The notify hook is the registration contract's representative case,
          # asserted once, in the fixture-monitored block.
          assertion =
            let
              node = config.services.prometheus.exporters.node;
              unit = config.systemd.services."prometheus-node-exporter";
              scrape = config.services.telemetry.scrape.node;
            in
            scrape.target == node.listenAddress
            && scrape.port == node.port
            && scrape.labels.instance == "${config.networking.hostName}:${toString node.port}"
            && lib.hasInfix "--web.listen-address ${node.listenAddress}:${toString node.port}" unit.serviceConfig.ExecStart
            && !(builtins.elem node.port config.networking.firewall.allowedTCPPorts);
          message = "fixture: the node-exporter scrape registration no longer tracks the exporter's own bind, or the bound port reached the firewall.";
        }
        {
          # The two Vector sinks must not become one: the log sink carries
          # systemd-journal records and nothing else, the health exporter only
          # Vector's own internal metrics. Every other value in these settings
          # is the aspect's own literal, or the consumer's own input rendered
          # back — the journald leaves own the validation and the rendering of
          # the opt-in scope.
          assertion =
            let
              sinks = config.services.vector.settings.sinks;
            in
            sinks.logs.inputs == [ "journald" ] && sinks.vector-health.inputs == [ "internal_metrics" ];
          message = "fixture: a Vector sink took the other lane's inputs — the health exporter became a second log path, or the log sink lost its journal-only input.";
        }
        {
          # Each active credential reaches the unit through its own placeholder
          # in the rendered environment, and the unit restarts for the secrets
          # it reads. The sopsFile/key bindings are the consumer's own inputs,
          # and the notify hook is the registration contract's representative
          # case, asserted in the fixture-monitored block.
          assertion =
            let
              template = config.sops.templates."otel-collector.env";
            in
            # The env file binds exactly the active credentials, each to its own
            # placeholder. Line order is not part of the contract, so compare
            # the lines as a set rather than pinning the provider's iteration
            # order.
            lib.sort (a: b: a < b) (lib.splitString "\n" (lib.removeSuffix "\n" template.content))
            == lib.sort (a: b: a < b) [
              "OTELCOL_token=${config.sops.placeholder."otel-collector/token"}"
              "OTELCOL_metricsToken=${config.sops.placeholder."otel-collector/metricsToken"}"
            ]
            && builtins.elem "opentelemetry-collector.service" template.restartUnits
            &&
              builtins.elem "opentelemetry-collector.service"
                config.sops.secrets."otel-collector/token".restartUnits
            &&
              config.systemd.services.opentelemetry-collector.serviceConfig.EnvironmentFile == [
                template.path
              ];
          message = "fixture: the otel-collector environment no longer maps each active credential to its own placeholder, or the unit is not restarted for the secrets it reads.";
        }
        {
          # The alerting path end to end: vmalert renders the consumer's rule
          # file and points at the bound datasource and notifier; Alertmanager
          # listens on loopback with the configuration the build checked, and
          # its webhook receiver posts back into the notify daemon's own
          # Alertmanager route; both units register their failure.
          assertion =
            let
              vmalertUnit = config.systemd.services."vmalert-fixture";
              alertmanagerUnit = config.systemd.services.alertmanager;
              alertmanager = config.services.prometheus.alertmanager;
              receiverUrl =
                (builtins.head (builtins.head alertmanager.configuration.receivers).webhook_configs).url;
            in
            config.services.vmalert.instances.fixture.enable
            && lib.hasInfix "-datasource.url=http://127.0.0.1:8428" vmalertUnit.serviceConfig.ExecStart
            && lib.hasInfix "-notifier.url=http://127.0.0.1:9093" vmalertUnit.serviceConfig.ExecStart
            && lib.hasInfix "-httpListenAddr=127.0.0.1:8880" vmalertUnit.serviceConfig.ExecStart
            && lib.hasInfix "-rule=/etc/vmalert-fixture/rules.yml" vmalertUnit.serviceConfig.ExecStart
            && lib.hasInfix "FixtureWatchdog" (
              builtins.toJSON config.environment.etc."vmalert-fixture/rules.yml".source.value
            )
            && config.services.notify.events."vmalert-fixture".failure != null
            && vmalertUnit.onFailure != [ ]
            && alertmanager.enable
            && alertmanager.listenAddress == "127.0.0.1"
            && alertmanager.checkConfig
            && !alertmanager.openFirewall
            &&
              receiverUrl == "http://127.0.0.1:${toString config.services.notify.port}/alertmanager?topic=infra"
            && lib.hasInfix "--web.listen-address 127.0.0.1:9093" alertmanagerUnit.serviceConfig.ExecStart
            && config.services.notify.events.alertmanager.failure != null
            && alertmanagerUnit.onFailure != [ ];
          message = "fixture: the alerting path (vmalert's bound datasource/notifier and rendered rules, alertmanager's loopback bind, checked config, webhook receiver, or either unit's notify ownership) regressed.";
        }
      ];

      # A real unit for the notification contract to hook.
      systemd.services.fixture-monitored.script = "true";

      # The v2 consumer wiring, verbatim from docs/contracts/builders.md:
      # trust projection (exactly the profile's hosts) + scheduling from the
      # resolved specs. nixpkgs renders /etc/nix/machines from buildMachines.
      programs.ssh.knownHosts = resolve.knownHosts resolvedProfile;
      programs.ssh.extraConfig = resolve.sshConfig resolvedProfile;
      nix.distributedBuilds = true;
      nix.buildMachines = resolve.buildMachines resolvedProfile;

      # Consumer-side override wins over the aspect's mkDefault.
      virtualisation.podman.autoPrune.dates = "daily";

      # Two containers exercise the guard: the default unit name and a renamed
      # one (nixpkgs names units from `serviceName`).
      virtualisation.oci-containers.containers = {
        fixture-container.image = "docker.io/library/hello-world:latest";
        fixture-renamed = {
          image = "docker.io/library/hello-world:latest";
          serviceName = "fixture-custom-name";
        };
      };

      services = {
        # The KEY is the hub's public half — policy, not a secret.
        beszel-agent = {
          key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE1AAAAIfixtureplaceholderpublickeybody0000 fixture";
        };

        niks3-cache = {
          s3.endpoint = "s3.invalid";
          cacheUrl = "https://cache.invalid";
          secretFiles = {
            host = fixtureSecretFile;
            apiToken = fixtureSecretFile;
          };
        };

        niks3-publisher = {
          serverUrl = "http://cache.invalid:5751";
          secretFiles.apiToken = fixtureSecretFile;
        };

        notify = {
          secretFiles = {
            host = fixtureSecretFile;
            hostSystem = fixtureSecretFile;
          };

          telegram = {
            chatId = "-1000000000000";
            topics = {
              infra = "2";
            };
            defaultTopic = "infra";
          };

          ntfy = {
            enable = true;
            serverUrl = "http://127.0.0.1:8082";
            topics = {
              infra = "infra";
            };
            defaultTopic = "infra";
          };
        };

        tailscale.secretFiles.auth = fixtureSecretFile;

        # The consumer owns every binding below: the alertmanager aspect
        # contributes the loopback default and the failure registration, the
        # vmalert aspect the validation and the registrations — neither enables
        # anything on its own.
        prometheus.alertmanager = {
          enable = true;
          configuration = {
            route = {
              receiver = "notify";
              group_by = [ "alertname" ];
            };
            receivers = [
              {
                name = "notify";
                webhook_configs = [
                  {
                    # The receiver is the notify daemon's Alertmanager route,
                    # on the topic the routing policy declares.
                    url = "http://127.0.0.1:${toString config.services.notify.port}/alertmanager?topic=infra";
                  }
                ];
              }
            ];
          };
        };

        vmalert.instances.fixture = {
          enable = true;
          settings = {
            "datasource.url" = "http://127.0.0.1:8428";
            "notifier.url" = [ "http://127.0.0.1:9093" ];
            # The management endpoint is bound explicitly: the aspect refuses an
            # instance that would otherwise inherit vmalert's all-interface
            # default.
            "httpListenAddr" = "127.0.0.1:8880";
          };
          # A trivial always-firing watchdog: the rule file the fixture host's
          # unit loads.
          rules.groups = [
            {
              name = "fixture";
              rules = [
                {
                  alert = "FixtureWatchdog";
                  expr = "vector(1)";
                  for = "0m";
                  labels.severity = "warning";
                  annotations.summary = "fixture always-firing watchdog";
                }
              ];
            }
          ];
        };

        telemetry = {
          # Explicit admission: this fixture host is the local-plus-network
          # gateway, so it accepts all three signals on its OTLP input and binds
          # an additional ingress alongside the loopback producer listener.
          otlp = {
            signals = [
              "traces"
              "metrics"
              "logs"
            ];
            ingress = {
              host = "100.64.0.9";
            };
          };
          # The log path is opt-in and carries its own endpoint: the consumer
          # names the backend, the aspect names none.
          journald = {
            enable = true;
            includeUnits = [ "fixture-monitored" ];
            sink.endpoint = "http://victorialogs.invalid:9428/insert/jsonline";
          };
          scrape = {
            # A service's own metrics surface. Port 9187, deliberately not the
            # node exporter's 9100: that target belongs to the node-exporter
            # aspect's registration.
            fixture-app = {
              target = "127.0.0.1";
              port = 9187;
              labels.service = "fixture-app";
            };
            fixture-sidecar = {
              target = "127.0.0.1";
              port = 9101;
              metricsPath = "/metrics/extra";
              interval = "15s";
            };
            # The collector's own delivery-health endpoint, registered through
            # the ordinary producer interface: the mechanism exposes loopback
            # metrics, the consumer decides whether to scrape them.
            otel-collector-health = {
              target = "127.0.0.1";
              port = 9464;
            };
          };
          destinations = {
            # An LLM-observability sink (Langfuse/Latitude-style): traces only,
            # so the default fanout must never hand it metrics or logs.
            secure = {
              protocol = "otlp-http";
              endpoint = "https://telemetry.invalid";
              signals = [ "traces" ];
              headers.Authorization = {
                secret = "token";
                prefix = "Bearer ";
              };
            };
            plain = {
              protocol = "otlp-grpc";
              endpoint = "http://gateway.invalid:4317";
              signals = [
                "traces"
                "metrics"
                "logs"
              ];
            };
            # The two metrics stores the scrape realization forwards to.
            victoria = {
              protocol = "prometheus-remote-write";
              endpoint = "http://metrics.invalid/api/v1/write";
              signals = [ "metrics" ];
            };
            archive = {
              protocol = "prometheus-remote-write";
              endpoint = "https://archive.invalid/api/v1/write";
              signals = [ "metrics" ];
              headers.Authorization = {
                secret = "metricsToken";
                prefix = "Bearer ";
              };
            };
          };
          # Scraped metrics leave vmagent over Prometheus remote write only, so
          # the metrics fanout is selected explicitly: both remote-write stores,
          # and not the OTLP gateway that also accepts metrics. Selecting the
          # fanout is the consumer's call; nothing is dropped silently.
          pipelines.metrics = [
            "victoria"
            "archive"
          ];
          pipelines.logs = [ "plain" ];
          secretFiles.token = fixtureSecretFile;
          secretKeys.token = "otel/token";
          secretFiles.metricsToken = fixtureSecretFile;
          secretKeys.metricsToken = "metrics/token";
        };

        otel-collector = {
          resourceAttributes."host.name" = "fixture-host";
          processors.attributes.actions = [
            {
              key = "fixture.attribute";
              action = "insert";
              value = "fixture";
            }
          ];
        };
      };

      # A unit owned by this module, registered on the notification contract:
      # failure severity defaulted (warning), success pruned (a stop of a
      # oneshot job is not news).
      services.notify.events.fixture-monitored = {
        failure = { };
      };

    };
in
{
  # Fleet inventory additions at flake level: placeholder key material, no
  # real builder endpoint or host key belongs in this repository. The NixOS
  # fixture below consumes the fleet facts through the documented consumer
  # wiring (resolveBuildProfile -> nix.settings), exercising the same path
  # an external consumer runs.
  fleet = {
    hosts.fixture-host = {
      system = "x86_64-linux";
      tailscale.hostname = "fixture-host";
      hostNames = [ "fixture-host" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIxTuRe0000000000000000000000000000000000 fixture@invalid";

      capabilities.nixBuilder = {
        enable = true;
        maxJobs = 2;
      };
    };

    externalBuilders.fixture-external = {
      uri = "ssh-ng://builder.invalid";
      systems = [ "aarch64-linux" ];
      publicHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureExternal0000000000000000000000 fixture@invalid";
    };

    buildProfiles.fixture = {
      hosts.fixture-host = { };
      external.fixture-external = { };
    };
  };

  configurations.nixos = lib.listToAttrs (
    lib.forEach config.systems (system: {
      name = "fixture-${builtins.replaceStrings [ "_" ] [ "-" ] system}";
      value.module = {
        imports = [
          fixtureModule
          {
            nixpkgs.hostPlatform = lib.mkForce system;
          }
        ];
        # Module arg wiring: the consumer's flake-level closure over its fleet
        # config, handed to the NixOS module (a NixOS module cannot read flake
        # config itself — that constraint shaped the whole v2 API).
        _module.args.resolvedProfile = resolvedProfile;
      };
    })
  );

  # The guard is the only thing between a secret's contents and vmagent's
  # positional argument parsing, and it is a shell script rather than a Nix
  # value, so its refusal is proven by running it — with the values it must
  # refuse and the ones it must not.
  perSystem =
    { system, ... }:
    let
      pkgs = inputs.nixpkgs.legacyPackages.${system};

      # The contract leaves: one independent check per throwaway contract
      # evaluation, so the fixture host above never forces the nested
      # evaluations its assertions used to carry.
      contract = contractLeaves system;

      # A leaf passes as a trivial derivation — the name still exists as a
      # check — and fails as the named error at evaluation, so a contract break
      # is never mistakable for an incidental evaluation error.
      contractLeaf =
        name:
        { message, ok }:
        if ok then pkgs.runCommand "check-${name}" { } "touch $out" else throw message;

      contractChecks = lib.mapAttrs contractLeaf contract;
    in
    {
      # One check per contract leaf. A leaf is an ordinary check name, so a new
      # contract keeps being an ordinary `checks.<name>` build in CI.
      checks = contractChecks // {
        vmagent-secret-guard =
          pkgs.runCommand "vmagent-secret-guard-check"
            {
              nativeBuildInputs = [
                pkgs.coreutils
                pkgs.gnugrep
              ];
            }
            ''
              set -euo pipefail
              guard=${guardScriptFor system}

              refuse() {
                if VMAGENT_probe="$1" "$guard" VMAGENT_probe 2>refusal.txt; then
                  echo "vmagent-secret-guard: accepted a value that changes argument parsing ($2)" >&2
                  exit 1
                fi
                grep -q "refusing to start" refusal.txt || {
                  echo "vmagent-secret-guard: refusal for $2 was not the named error" >&2
                  cat refusal.txt >&2
                  exit 1
                }
              }
              accept() {
                VMAGENT_probe="$1" "$guard" VMAGENT_probe || {
                  echo "vmagent-secret-guard: rejected a representable value ($2)" >&2
                  exit 1
                }
              }

              # A comma is the leak this guard exists for: it adds an array
              # element, so the next destination receives arguments meant for
              # this one. The rest are the parser's other structural characters,
              # and a newline can start a new header line.
              refuse 'PRIMARY,X-Probe: LEAKED' 'comma'
              refuse 'a,b' 'comma (short)'
              refuse 'a]b' 'closing bracket'
              refuse 'a{b' 'opening brace'
              refuse 'a(b' 'opening parenthesis'
              refuse "q'w" 'single quote'
              refuse 'p^^r' 'header separator'
              refuse 'c^d' 'caret'
              refuse $'e\nf' 'embedded newline'
              refuse $'g\n' 'trailing newline'
              refuse $'h\ri' 'carriage return'

              # Bearer/basic credentials and the shapes consumers actually bind
              # must keep working, including one that is only structurally safe.
              accept 'sk-abc123DEF' 'opaque token'
              accept 'AbC0._~-+/=' 'base64url and padding'
              accept 'user:pa55word' 'basic-auth style'
              accept 'project-1234' 'identifier'
              accept "" 'empty'

              touch $out
            '';
      };
    };
}
