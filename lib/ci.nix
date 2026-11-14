# The claim shape flakeModules.ci produces, read by the cache's trust rules too, so
# the two cannot disagree. nixbot names a workload-identity effect by its dotted
# attribute path from the onPush job (nixbot_effects/eval.py _walk_expr).
rec {
  pushJob = "default";
  retainName = "cache-retain";
  releaseName = "cache-release";
  retainEffect = "${pushJob}.${retainName}";
  releaseEffect = "${pushJob}.${releaseName}";
  # Pins are `<namespace>-<system>` (and `-<n>` for older generations).
  pinNamespace = name: branch: "${name}-${branch}";
  releaseNamespace = name: "${name}-release";
}
