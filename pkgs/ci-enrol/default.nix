# Reconciles enrolled repositories' forge side; flakeModules.ciFederation bakes the plan.
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
    exec ${enrol} "$@" ${plan}
  '';
}
