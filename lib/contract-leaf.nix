# Check plumbing shared by the feature-owned `*-checks.nix` files.
#
# A *case* is `{ message; ok; }`: the invariant it protects and whether it still
# holds. A *leaf* is one `checks.<name>` entry built from one or more cases. It
# passes as a trivial derivation and fails naming every failing case, because an
# `&&` chain reports the first failure and hides the rest.
{
  lib,
  pkgs,
}:
let
  inherit (builtins)
    all
    filter
    ;
in
rec {
  # A configuration's failing assertions, as data. A `throw` aborts evaluation
  # and `tryEval` returns no text, so an assertion-delivered rejection is the
  # only kind whose named error a case can pin; a throw-delivered one is pinned
  # as "this input is refused", and the case's own message names the invariant.
  assertionFailures =
    config:
    map (assertion: assertion.message) (filter (assertion: !assertion.assertion) config.assertions);

  leaf =
    name: cases:
    let
      failed = filter (case: !case.ok) cases;
    in
    if failed == [ ] then
      pkgs.runCommand "check-${name}" { } "touch $out"
    else
      throw "${name}: ${lib.concatMapStringsSep "; " (case: case.message) failed}";

  # The contract's refusals are delivered as assertions, which NixOS supplies an
  # option for. The bare evaluation declares the same option so they stay
  # readable as data, and evaluates the contract module alone — no aspect, sops
  # or systemd — the cheapest substrate that still runs the contract's option
  # types, its throws and its assertions.
  telemetryContractModule = {
    imports = [ ./telemetry-contract.nix ];
    options.assertions = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            assertion = lib.mkOption { type = lib.types.bool; };
            message = lib.mkOption { type = lib.types.str; };
          };
        }
      );
      default = [ ];
    };
  };

  telemetryContract =
    values:
    (lib.evalModules {
      specialArgs = { inherit lib; };
      modules = [
        telemetryContractModule
        { services.telemetry = values; }
      ];
    }).config;

  # Accepted: every assertion holds and nothing forced along the way errored. A
  # partial declaration is accepted here only if nothing forces it, which is
  # what "inert" means.
  telemetryAccepts =
    values:
    (builtins.tryEval (all (assertion: assertion.assertion) (telemetryContract values).assertions))
    .success;

  # Refused: the evaluation throws somewhere — a contract `throw` or a failed
  # option-type merge. Both abort evaluation, so the case pins the refusal and
  # its message names the branch.
  telemetryRefuses =
    values:
    let
      config = telemetryContract values;
    in
    !(builtins.tryEval (
      builtins.deepSeq [
        config.services.telemetry.resolvedPipelines
        config.services.telemetry.resolvedRoutePipelines
      ] true
    )).success;
}
