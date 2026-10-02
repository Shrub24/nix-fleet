# The Bifrost dashboard: a Vite + React single-page app built from the same
# pinned source as the server. Its static output is the directory the Go binary
# embeds through `//go:embed all:ui`, so this is a build input for the `bifrost`
# package rather than a separately consumable program.
{
  buildNpmPackage,
  lib,
  src,
  version,
}:

buildNpmPackage {
  pname = "bifrost-ui";
  inherit src version;

  npmDepsHash = "sha256-cOswnT4ZahWX66h9oiw4t3r5GZeOH/yjbnTCAsjVgnw=";

  # `build` is vite build + typecheck + a copy step into the Go module tree,
  # which the Go derivation does itself; `build-enterprise` is that same build
  # without the copy. The enterprise UI is not a build script variant — vite
  # selects it from the presence of `app/enterprise`, which the OSS source does
  # not have — and the OSS container image builds the UI with this same script.
  npmBuildScript = "build-enterprise";

  # vite writes the static export to `out/`. Install those assets directly
  # instead of the node_modules tree npm's install hook would produce.
  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    cp -R --no-preserve=mode,ownership,timestamps out/. "$out/"

    runHook postInstall
  '';

  meta = {
    description = "Bifrost dashboard assets, embedded by the bifrost package";
    homepage = "https://github.com/maximhq/bifrost";
    license = lib.licenses.asl20;
  };
}
