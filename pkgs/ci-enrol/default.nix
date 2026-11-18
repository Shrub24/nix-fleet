# Enrols repositories in a nixbot instance; flakeModules.ciFederation bakes the plan.
{
  writers,
  writeShellApplication,
  gh,
}:
plan:
let
  enrol = writers.writePython3 "ci-enrol-reconcile" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./enrol.py);
in
writeShellApplication {
  name = "ci-enrol";
  runtimeInputs = [ gh ];
  text = ''
    CI_ENROL_PLAN=${plan} exec ${enrol} "$@"
  '';
}
