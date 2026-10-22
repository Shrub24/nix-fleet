{
  lib,
  buildGoModule,
  fetchFromGitHub,
  makeWrapper,
  shellcheck,
}:
buildGoModule (finalAttrs: {
  pname = "jactionlint";
  version = "2.3.0";
  src = fetchFromGitHub {
    owner = "jdx";
    repo = "jactionlint";
    tag = "v${finalAttrs.version}";
    hash = "sha256-/gCh+9NmRDsoqrcLl287qxmpiLnb2hF3vb2KTNP+BXM=";
  };
  vendorHash = "sha256-SnP9Siop3zgGrVMuHU2IOqDkPKnfyJZVxUB/iBV8hIA=";
  subPackages = [ "cmd/jactionlint" ];
  ldflags = [
    "-s"
    "-w"
    "-X github.com/jdx/jactionlint/v2.version=${finalAttrs.version}"
  ];
  env.GOTOOLCHAIN = "local";
  nativeBuildInputs = [ makeWrapper ];
  postInstall = ''
    wrapProgram $out/bin/jactionlint --prefix PATH : ${lib.makeBinPath [ shellcheck ]}
  '';
  meta = {
    description = "GitHub Actions workflow and composite-action linter";
    homepage = "https://github.com/jdx/jactionlint";
    license = lib.licenses.mit;
    mainProgram = "jactionlint";
  };
})
