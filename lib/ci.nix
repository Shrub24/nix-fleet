# The claim shape flakeModules.ci produces, read by the cache's trust rules too, so
# the two cannot disagree. nixbot names a workload-identity effect by its dotted
# attribute path from the onPush job (nixbot_effects/eval.py _walk_expr).
lib:
let
  endpoints = import ./service-endpoints.nix lib;
in
rec {
  pushJob = "default";
  retainName = "cache-retain";
  releaseName = "cache-release";
  retainEffect = "${pushJob}.${retainName}";
  releaseEffect = "${pushJob}.${releaseName}";
  # Pins are `<namespace>-<system>` (and `-<n>` for older generations).
  pinNamespace = name: branch: "${name}-${branch}";
  releaseNamespace = name: "${name}-release";

  # The instance every repository's CI binds, from the canonical inventory.
  resolveInstance =
    fleet:
    let
      need = value: fact: if value == null then throw "fleet: ci.${fact} must be set" else value;
      controller = need fleet.ci.controller "controller";
    in
    {
      inherit
        ((fleet.hosts.${controller} or (throw "fleet: ci.controller '${controller}' is not a fleet host")))
        system
        ;
      cacheUrl = endpoints.cacheSubstituterUrl fleet;
      writeEndpoint = endpoints.cacheApiUrl fleet;
      nixbotUrl = endpoints.url fleet {
        service = "nixbot";
        endpoint = "web";
        via = "public";
      };
      appId = need fleet.ci.githubAppId "githubAppId";
    };
}
