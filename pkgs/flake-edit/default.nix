# flake-edit, the update transaction's tag resolver, at a pinned release carrying
# the patches that make its selection follow the maintainer's releases and the
# input's version policy. Drop each patch once a flake-edit release carries it.
{
  lib,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  openssl,
}:

rustPlatform.buildRustPackage (finalAttrs: {
  pname = "flake-edit";
  version = "0.4.0";

  src = fetchFromGitHub {
    owner = "a-kenji";
    repo = "flake-edit";
    rev = "v${finalAttrs.version}";
    hash = "sha256-Cyv26VH7XvsMNAMBOImQGoadr0LeqBpapaxKFAEM88s=";
  };

  patches = [
    ./0001-update-select-tags-by-a-per-input-version-regex.patch
    ./0002-update-follow-the-latest-release-exclude-pre-release.patch
  ];

  # The patches add a direct dependency already in the lock, which edits Cargo.lock.
  cargoDeps = rustPlatform.fetchCargoVendor {
    inherit (finalAttrs)
      pname
      version
      src
      patches
      ;
    hash = "sha256-b1TiuciUk33rhnkmE5AUM1PL7kOEaKRcYqZo3kh5s7I=";
  };

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ openssl ];
  env.ASSET_DIR = "target/assets";

  meta = {
    description = "Edit your flake inputs with ease";
    homepage = "https://github.com/a-kenji/flake-edit";
    license = lib.licenses.mit;
    mainProgram = "flake-edit";
  };
})
