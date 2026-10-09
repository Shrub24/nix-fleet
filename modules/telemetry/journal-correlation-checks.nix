# Runtime-backed validation for journal identity enrichment and trace-context
# normalization. The built-in Vector binary is exercised over small independent
# records; the NixOS leaf checks the production transform is wired before the
# persistent HTTP sink and that its opt-out removes correlation parsing.
{
  config,
  inputs,
  lib,
  ...
}:
{
  perSystem =
    { system, ... }:
    let
      pkgs = inputs.nixpkgs.legacyPackages.${system};
      inherit (import ../../lib/contract-leaf.nix { inherit lib pkgs; }) leaf;
      aspects = config.flake.modules.nixos;
      host =
        (lib.nixosSystem {
          inherit system;
          modules = [
            inputs.sops-nix.nixosModules.sops
            aspects.telemetry-vector
            {
              services.telemetry = {
                identity = {
                  hostName = "canonical-host";
                  environment = "test";
                };
                journald = {
                  enable = true;
                  includeUnits = [ "sshd.service" ];
                  sink.endpoint = "http://logs.invalid/insert/jsonline";
                };
              };
            }
            {
              system.stateVersion = "25.11";
              boot.loader.grub.enable = false;
              fileSystems."/" = {
                device = "nodev";
                fsType = "tmpfs";
              };
            }
          ];
        }).config;
      optedOut =
        (lib.nixosSystem {
          inherit system;
          modules = [
            inputs.sops-nix.nixosModules.sops
            aspects.telemetry-vector
            {
              services.telemetry.journald = {
                enable = true;
                includeAll = true;
                normalizeTraceContext = false;
                sink.endpoint = "http://logs.invalid/insert/jsonline";
              };
            }
            {
              system.stateVersion = "25.11";
              boot.loader.grub.enable = false;
              fileSystems."/" = {
                device = "nodev";
                fsType = "tmpfs";
              };
            }
          ];
        }).config;
      program = builtins.toFile "journal-correlation.vrl" host.services.vector.settings.transforms.journald-correlation.source;
      identityProgram = builtins.toFile "journal-identity.vrl" host.services.vector.settings.transforms.journald-identity.source;
      binary = "${pkgs.vector}/bin/vector";
      records = builtins.toFile "journal-correlation-input.jsonl" ''
        {"message":"{\"trace_id\":\"ABCDEF1234567890ABCDEF1234567890\",\"span_id\":\"ABCDEF1234567890\",\"host_name\":\"attacker\",\"_SYSTEMD_UNIT\":\"attacker.service\"}","_SYSTEMD_UNIT":"sshd.service","_HOSTNAME":"node"}
        {"message":"{\"trace_id\":\"abcdef1234567890abcdef1234567890\"}"}
        {"message":"{oops","_SYSTEMD_UNIT":"sshd.service"}
        {"message":"{\"trace_id\":\"00000000000000000000000000000000\"}"}
        {"message":"{\"trace_id\":123}"}
        {"trace_id":"bad","message":"{\"trace_id\":\"abcdef1234567890abcdef1234567890\"}"}
        {"trace_id":"ABCDEF1234567890ABCDEF1234567890","span_id":"abcdef1234567890","message":"plain"}
        {"trace_id":"abcdef1234567890abcdef1234567890","span_id":"bad","message":"plain"}
        {"span_id":"abcdef1234567890","message":"plain"}
        {"message":"hello","parsed":"keep-parsed","candidate":"keep-candidate","candidateValid":"keep-valid","spanRootPresent":"keep-span-presence"}
        {"trace_id":"11111111111111111111111111111111","message":"{\"trace_id\":\"22222222222222222222222222222222\"}"}
      '';
      # The invariant set, run against any stage's recorded output. The
      # identity-only stage is the corruption probe: these invariants must not
      # hold without the authored transform, or the transform is not
      # load-bearing and the assertions prove nothing.
      assertions = builtins.toFile "journal-correlation-assertions.py" ''
        import json, sys
        rows = [json.loads(line) for line in open(sys.argv[1])]
        assert len(rows) == 11, "malformed or plain messages must survive"
        first = rows[0]
        assert first["trace_id"] == "abcdef1234567890abcdef1234567890"
        assert first["message"].startswith("{") and first["_SYSTEMD_UNIT"] == "sshd.service"
        assert first["host_name"] == "canonical-host" and first["environment"] == "test"
        assert first["span_id"] == "abcdef1234567890", "valid span paired with trace must promote"
        assert rows[1]["trace_id"] == "abcdef1234567890abcdef1234567890" and "span_id" not in rows[1]
        for row in rows[2:6]:
            assert "trace_id" not in row, "malformed/non-string/zero/invalid preferred trace must not promote"
        assert rows[6]["trace_id"] == "abcdef1234567890abcdef1234567890"
        assert rows[6]["span_id"] == "abcdef1234567890"
        assert "span_id" not in rows[7] and "span_id" not in rows[8]
        assert rows[9]["message"] == "hello"
        assert rows[9]["parsed"] == "keep-parsed"
        assert rows[9]["candidate"] == "keep-candidate"
        assert rows[9]["candidateValid"] == "keep-valid"
        assert rows[9]["spanRootPresent"] == "keep-span-presence"
        assert rows[10]["trace_id"] == "11111111111111111111111111111111", "a valid source carrier must govern message JSON"
        assert rows[10]["message"] == "{\"trace_id\":\"22222222222222222222222222222222\"}", "the original message must survive normalization"
      '';
      runtime = pkgs.runCommand "journal-correlation-runtime" { nativeBuildInputs = [ pkgs.python3 ]; } ''
        ${binary} vrl --quiet --program ${identityProgram} --input ${records} --print-object > identified.jsonl
        ${binary} vrl --quiet --program ${program} --input identified.jsonl --print-object > result.jsonl
        ${pkgs.python3}/bin/python ${assertions} result.jsonl
        if ${pkgs.python3}/bin/python ${assertions} identified.jsonl >/dev/null 2>&1; then
          echo "the identity-only stage satisfies the normalization invariants: the correlation transform is not load-bearing" >&2
          exit 1
        fi
        touch $out
      '';
      distinctHost =
        (lib.nixosSystem {
          inherit system;
          modules = [
            inputs.sops-nix.nixosModules.sops
            aspects.telemetry-vector
            { networking.hostName = "machine-name"; }
            { services.telemetry.identity.hostName = "canonical-name"; }
            {
              services.telemetry.journald = {
                enable = true;
                includeAll = true;
                sink.endpoint = "http://logs.invalid/insert/jsonline";
              };
            }
            {
              system.stateVersion = "25.11";
              boot.loader.grub.enable = false;
              fileSystems."/" = {
                device = "nodev";
                fsType = "tmpfs";
              };
            }
          ];
        }).config;
      check = leaf "journal-correlation-wiring" [
        {
          message = "the Vector transform no longer precedes the buffered sink or identity enrichment";
          ok =
            host.services.vector.settings.sinks.logs.inputs == [ "journald-correlation" ]
            && host.services.vector.settings.transforms.journald-correlation.inputs == [ "journald-identity" ]
            && host.services.vector.settings.transforms.journald-identity.inputs == [ "journald" ]
            && host.services.vector.settings.sinks.logs.buffer.type == "disk";
        }
        {
          message = "the explicit opt-out still parses or normalizes correlation";
          ok =
            !(optedOut.services.vector.settings.transforms ? journald-correlation)
            && optedOut.services.vector.settings.sinks.logs.inputs == [ "journald-identity" ];
        }
        {
          message = "identity enrichment writes an environment field when the host binds none";
          ok =
            let
              source = optedOut.services.vector.settings.transforms.journald-identity.source;
            in
            lib.hasInfix "host_name" source && !(lib.hasInfix "environment" source);
        }
        {
          message = "Vector health instance identity changed with the canonical host override";
          ok = distinctHost.services.telemetry.scrape.vector-health.labels.instance == "machine-name:vector";
        }
        {
          message = "trace context leaked into stream partition fields";
          ok =
            !(builtins.elem "trace_id" host.services.telemetry.journald.sink.streamFields)
            && !(builtins.elem "span_id" host.services.telemetry.journald.sink.streamFields);
        }
        {
          message = "trace context leaked into generated metric labels";
          ok =
            !(builtins.any (
              source:
              builtins.any (key: lib.hasInfix "trace" key || lib.hasInfix "span" key) (
                builtins.attrNames source.labels
              )
            ) (lib.attrValues host.services.telemetry.scrape));
        }
      ];
    in
    {
      checks.journal-correlation-runtime = runtime;
      checks.journal-correlation-wiring = check;
    };
}
