# The journald provider (`modules/telemetry/vector.nix`) and its contract data:
# what shipping refuses by name, what the whole-journal opt-in renders, and what
# stays inert without a logs realization.
{
  lib,
  config,
  inputs,
  ...
}:
let
  fixtureSecretFile = ../flake/fixture-secrets.yaml;
  fixtureHost = {
    boot.loader.grub.enable = false;
    fileSystems."/" = {
      device = "nodev";
      fsType = "tmpfs";
    };
  };
in
{
  perSystem =
    { system, ... }:
    let
      pkgs = inputs.nixpkgs.legacyPackages.${system};
      check = import ../../lib/contract-leaf.nix { inherit lib pkgs; };
      inherit (check)
        assertionFailures
        leaf
        telemetryAccepts
        telemetryContract
        ;
      aspects = config.flake.modules.nixos;
      hostFor =
        aspects': values:
        (lib.nixosSystem {
          inherit system;
          modules = [
            inputs.sops-nix.nixosModules.sops
          ]
          ++ aspects'
          ++ [
            { services.telemetry = values; }
            { system.stateVersion = "25.11"; }
            fixtureHost
          ];
        }).config;
      refusesWith =
        message: values:
        builtins.any (lib.hasPrefix message) (assertionFailures (telemetryContract values));
      journaldSink = "http://victorialogs.invalid:9428/insert/jsonline";
      vectorRejects =
        values:
        let
          settings = (hostFor [ aspects.telemetry-vector ] values).services.vector.settings;
        in
        !(builtins.tryEval (builtins.deepSeq settings true)).success;
      wholeJournal = hostFor [ aspects.telemetry-logs ] {
        journald = {
          includeAll = true;
          sink.endpoint = journaldSink;
        };
      };
      listedUnits = hostFor [ aspects.telemetry-vector ] {
        journald = {
          enable = true;
          includeUnits = [ "fixture-monitored" ];
          sink.endpoint = journaldSink;
        };
      };
      # Selecting telemetry for metrics or traces must not start the log shipper
      # or publish its delivery health: both belong to the logs realization.
      tracesOnly = hostFor [ aspects.telemetry-otlp ] {
        otlp.signals = [ "traces" ];
        destinations.plain = {
          protocol = "otlp-grpc";
          endpoint = "http://gateway.invalid:4317";
          signals = [ "traces" ];
        };
      };
    in
    {
      checks.telemetry-journald-contract = leaf "telemetry-journald-contract" [
        {
          message = "shipping enabled with no endpoint is no longer refused at render time";
          ok = vectorRejects { journald.enable = true; };
        }
        {
          message = "a disk buffer under Vector's floor is no longer refused at render time";
          ok = vectorRejects {
            journald = {
              enable = true;
              sink.endpoint = journaldSink;
              buffer.maxSizeMb = 100;
            };
          };
        }
        {
          message = "a sink endpoint with no scheme is no longer refused by name";
          ok =
            refusesWith
              "telemetry: journald sink endpoint 'victorialogs.invalid:9428/insert/jsonline' must be an http:// or https:// URL"
              {
                journald.sink.endpoint = "victorialogs.invalid:9428/insert/jsonline";
              };
        }
        {
          message = "an empty allowlist is no longer refused by name";
          ok = refusesWith "telemetry: journald shipping is enabled with an empty includeUnits" {
            journald = {
              enable = true;
              sink.endpoint = journaldSink;
            };
          };
        }
        {
          message = "includeAll with a non-empty includeUnits is no longer refused by name";
          ok = refusesWith "telemetry: services.telemetry.journald.includeAll is true" {
            journald = {
              includeAll = true;
              includeUnits = [ "sshd.service" ];
              sink.endpoint = journaldSink;
            };
          };
        }
      ];

      checks.telemetry-journald-isolation = leaf "telemetry-journald-isolation" [
        {
          message = "the deliberate whole-journal opt-in is no longer accepted";
          ok =
            (builtins.tryEval (lib.asserts.checkAssertWarn wholeJournal.assertions wholeJournal.warnings true))
            .success;
        }
        {
          message = "includeAll no longer renders a whole-journal source without an include_units filter";
          ok = !(wholeJournal.services.vector.settings.sources.journald ? include_units);
        }
        {
          message = "Vector no longer reads only the current boot";
          ok = listedUnits.services.vector.settings.sources.journald.current_boot_only;
        }
        {
          message = "contract-only journald values are no longer accepted without a logs realization";
          ok = telemetryAccepts { journald.sink.endpoint = journaldSink; };
        }
        {
          message = "a dormant destination's bound but unused credential is no longer accepted";
          ok = telemetryAccepts {
            destinations.dormant = {
              protocol = "otlp-http";
              endpoint = "https://dormant.invalid";
              signals = [ "logs" ];
              headers.Authorization.secret = "idleToken";
            };
            secretFiles.idleToken = fixtureSecretFile;
            secretKeys.idleToken = "unused/token";
          };
        }
        {
          message = "contract-only journald allowlist data is no longer accepted";
          ok = telemetryAccepts {
            journald = {
              includeUnits = [ "fixture-monitored" ];
              sink.endpoint = journaldSink;
            };
          };
        }
        {
          message = "a traces-only composition starts Vector or publishes Vector's health registration";
          ok = !tracesOnly.services.vector.enable && !(tracesOnly.services.telemetry.scrape ? vector-health);
        }
      ];
    };
}
