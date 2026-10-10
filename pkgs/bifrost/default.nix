# Bifrost (maximhq) is the gateway in front of the fleet's model providers: one
# OpenAI-compatible HTTP service with its dashboard UI compiled into the binary.
#
# The Go module is built the way the project's own release builders build it.
# transports/go.mod pins published versions of bifrost/core, bifrost/framework
# and bifrost/plugins/*, and both .github/workflows/scripts/build-executables.sh
# (`GOWORK=off`) and transports/Dockerfile resolve exactly those — with no local
# module replaces. The build graph is therefore the published release graph for
# this revision, not this checkout's sibling module sources.
#
# The UI is built from the same revision and copied into the directory
# `//go:embed all:ui` embeds.
{
  lib,
  buildGo127Module,
  callPackage,
  fetchFromGitHub,
  runCommand,
  writeShellApplication,
  python3,
  nix-update,
  nixVersions,
}:

let
  # transports/version at the pinned revision.
  version = "2.2.6";

  src = fetchFromGitHub {
    owner = "maximhq";
    repo = "bifrost";
    rev = "8b4fce4f1709d66f9208d02f50552da522535f9e"; # tag transports/v2.2.6
    hash = "sha256-vgdsNg48Cd4qoOwFyQ9ahnC6darTyAGV4/LkQSiBXzk=";
  };

  # The two subtrees the binary is made of, split out of the fetched monorepo
  # at *build* time. Deriving them at evaluation (`lib.cleanSourceWith` over the
  # fetch output) is an import-from-derivation: the path only exists once the
  # fetch has run, so `nix flake check --no-build` and any fresh store fail on
  # it even though the same evaluation succeeds where the output is already
  # cached. Only these subtrees are needed anyway — `docs/` alone is 559 MiB of
  # the 626 MiB checkout.
  transportsSrc = runCommand "bifrost-transports-${version}" { } ''
    mkdir -p "$out"
    cp -R --no-preserve=mode,ownership,timestamps ${src}/transports/. "$out/"
    # Air's hot-reload config is the only thing in the module tree that no
    # build step reads (the config schema stays: the module's own tests read it).
    rm -f "$out/.air.toml" "$out/.air.debug.toml"
  '';

  uiSrc = runCommand "bifrost-ui-${version}" { } ''
    mkdir -p "$out"
    cp -R --no-preserve=mode,ownership,timestamps ${src}/ui/. "$out/"
  '';

  ui = callPackage ./ui.nix {
    src = uiSrc;
    inherit version;
  };
  goModule = {
    src = transportsSrc;

    # Locked module cache for the pinned go.mod/go.sum.
    vendorHash = "sha256-y9q3wdnWEfKekZWVrmbL+bvomWLNAmydx2ld08C2D5Y=";

    # go-sqlite3 compiles the SQLite amalgamation it carries, so CGO is
    # required and no SQLite build input is needed.
    env.CGO_ENABLED = "1";
  };

  bifrost = buildGo127Module (
    goModule
    // {
      pname = "bifrost";
      inherit version;

      subPackages = [ "bifrost-http" ];

      # The dashboard is a build input, not something the Go build produces.
      preBuild = ''
        rm -rf bifrost-http/ui
        mkdir -p bifrost-http/ui
        cp -R --no-preserve=mode,ownership,timestamps ${ui}/. bifrost-http/ui/
      '';

      # The module's test files stand up servers, stores and providers; the
      # released-binary path compiles without running them.
      doCheck = false;

      ldflags = [
        "-s"
        "-w"
        # Same value the release scripts stamp in (`v`+version).
        "-X main.Version=v${version}"
      ];

      meta = {
        # Per-release notes for the transport tag this build pins, so the
        # package-update report links the release a refresh moved to.
        changelog = "https://github.com/maximhq/bifrost/releases/tag/transports%2Fv${version}";
        description = "HTTP gateway for AI model providers with the embedded dashboard UI";
        homepage = "https://github.com/maximhq/bifrost";
        license = lib.licenses.asl20;
        mainProgram = "bifrost-http";
      };
    }
  );

  # Plugins compile as a package inside the same pinned transports module and
  # vendored dependency graph as the host. GOFLAGS, CGO and the Go toolchain are
  # inherited from the same buildGoModule builder, keeping shared package hashes
  # compatible for Go's runtime plugin loader.
  mkPlugin =
    { name, src }:
    buildGo127Module (
      goModule
      // {
        pname = "bifrost-plugin-${name}";
        inherit version;
        subPackages = [ ];
        doCheck = false;
        ldflags = [
          "-s"
          "-w"
        ];

        postPatch = ''
          mkdir -p "plugins/${name}"
          cp -R --no-preserve=mode,ownership,timestamps ${src}/. "plugins/${name}/"
        '';

        buildPhase = ''
          runHook preBuild
          go build -p "$NIX_BUILD_CORES" -buildmode=plugin -o "${name}.so" "./plugins/${name}"
          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          install -D -m 0555 "${name}.so" "$out/lib/bifrost/${name}.so"
          runHook postInstall
        '';

        meta = {
          description = "Bifrost ${name} Go plugin";
          homepage = "https://github.com/maximhq/bifrost";
          license = lib.licenses.asl20;
          platforms = lib.platforms.linux;
        };
      }
    );
in
bifrost.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    inherit mkPlugin ui;
    updateScript = lib.getExe (writeShellApplication {
      name = "bifrost-update";
      runtimeInputs = [
        python3
        nix-update
        nixVersions.latest
      ];
      text = ''
        exec python3 ${./update.py}
      '';
    });
  };
})
