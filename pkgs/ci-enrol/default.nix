# Reconciles enrolled repositories' forge side; flakeModules.ciFederation bakes the plan.
{
  writers,
  writeShellApplication,
  gh,
  nixbot-cli,
}:
plan:
let
  enrol = writers.writePython3 "ci-enrol-reconcile" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./enrol.py);
in
writeShellApplication {
  name = "ci-enrol";
  runtimeInputs = [
    gh
    nixbot-cli
  ];
  text = ''
    exec ${enrol} "$@" ${plan}
  '';
}
