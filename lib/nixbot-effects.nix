# The claim shape flakeModules.nixbotEffects produces, read by the cache's trust
# rules too, so the two cannot disagree. nixbot names a workload-identity effect by
# its dotted attribute path from the onPush job (nixbot_effects/eval.py _walk_expr).
rec {
  pushJob = "default";
  retainName = "cache-retain";
  retainEffect = "${pushJob}.${retainName}";
  # Rolling pins are `<namespace>-<system>`.
  pinNamespace = name: branch: "${name}-${branch}";
}
