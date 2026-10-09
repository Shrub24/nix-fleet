# prometheus-podman-exporter, vendored from NixOS/nixpkgs PR #507097
# ("prometheus-podman-exporter: init at 1.21.2") at
#   b859cd0bd7be2b0ea7d5810dab7c537e9c650a59
# package source
#   pkgs/by-name/pr/prometheus-podman-exporter/package.nix
# Upstream licence: Apache-2.0, maintainer `cobalt` (attribution kept in `meta`).
#
# HACK: the fleet's nixpkgs pin (151fa4e8ddfd) predates this PR, so the package
# exists here rather than in nixpkgs. Retire it — and the module adaptation in
# lib/podman-exporter.nix — once a fleet nixpkgs pin exposes
# `pkgs.prometheus-podman-exporter` and its
# `services.prometheus.exporters.podman` module, keeping
# `flake.modules.nixos.podman-exporter` and the `podman` scrape job name so
# consumers do not re-select a mechanism.
#
# `tags = [ "remote" ... ]` is load-bearing, not cosmetic: the `remote` build
# speaks the Podman REST API over `CONTAINER_HOST` (a socket), while the default
# build links libpod natively. Dropping it produces a binary that cannot start
# against the configured socket. The owned guest integration check exercises
# that package/service/socket seam.
{
  lib,
  buildGoModule,
  fetchFromGitHub,
  pkg-config,
  gpgme,
  libassuan,
  systemd,
  withBtrfs ? true,
  btrfs-progs,
}:
buildGoModule (finalAttrs: {
  pname = "prometheus-podman-exporter";
  version = "1.21.2";

  src = fetchFromGitHub {
    owner = "containers";
    repo = "prometheus-podman-exporter";
    tag = "v${finalAttrs.version}";
    hash = "sha256-7AU/LWRClwuPEEalhanglMlpXirzFELhdX+6lbu/6zA=";
  };

  buildInputs = [
    gpgme
    libassuan
    systemd
  ]
  ++ lib.optional withBtrfs btrfs-progs;
  nativeBuildInputs = [ pkg-config ];

  # Upstream's build flags, from the Makefile and hack/ scripts. `remote` selects
  # the REST-API client; `containers_image_openpgp` and `systemd` drop the cgo
  # dependencies the standard build pulls in.
  tags = [
    "remote"
    "containers_image_openpgp"
    "systemd"
  ]
  ++ lib.optionals (!withBtrfs) [
    "exclude_graphdriver_btrfs"
    "btrfs_noversion"
  ];

  ldflags = [
    # Upstream defines the version manually in a VERSION file instead of via
    # Go's embedded module metadata.
    "-X github.com/containers/prometheus-podman-exporter/cmd.buildVersion=${finalAttrs.version}"
    "-X github.com/containers/prometheus-podman-exporter/cmd.buildRevision=${lib.versions.major finalAttrs.version}"
    # this should be the git ref, for tags it is HEAD
    "-X github.com/containers/prometheus-podman-exporter/cmd.buildBranch=HEAD"
  ];

  # The source tree vendors its Go dependencies, so no separate proxy vendor
  # hash is needed.
  vendorHash = null;

  __structuredAttrs = true;

  # Upstream's test scripts require a running podman daemon and a real $HOME.
  doCheck = false;

  meta = {
    description = "Prometheus exporter for podman environments exposing containers, pods, images, volumes and networks information";
    homepage = "https://github.com/containers/prometheus-podman-exporter";
    license = lib.licenses.asl20;
    maintainers = with lib.maintainers; [ cobalt ];
    mainProgram = "prometheus-podman-exporter";
  };
})
