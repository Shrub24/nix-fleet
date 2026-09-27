# Create one SOPS-encrypted secret file from a template. Operator-local: the
# implementation lives here so both consumers bootstrap secrets identically,
# while the template tree, the target layout, and the creation rules stay
# consumer-side. See docs/contracts/secrets.md.
{
  lib,
  makeWrapper,
  python3Packages,
  sops,
}:

python3Packages.buildPythonApplication {
  pname = "sops-bootstrap";
  version = "1.0";
  src = ./.;
  format = "pyproject";
  nativeBuildInputs = [
    makeWrapper
    python3Packages.setuptools
  ];
  propagatedBuildInputs = with python3Packages; [
    jinja2
    pyyaml
  ];

  # sops is the encryptor this tool drives, so the package carries it rather
  # than relying on the caller's PATH.
  postFixup = ''
    wrapProgram $out/bin/sops-bootstrap \
      --prefix PATH : ${lib.makeBinPath [ sops ]} \
      --set PYTHONNOUSERSITE 1
  '';

  pythonImportsCheck = [ "sops_bootstrap" ];

  meta = {
    description = "Create one SOPS-encrypted secret file from a template";
    mainProgram = "sops-bootstrap";
  };
}
