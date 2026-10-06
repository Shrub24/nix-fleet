# Shared batch runner for the fleet package-update contract. It owns
# selection, ordering and failure reporting only; the updater tool and the
# package outputs come from the evaluated repository, so the same runner
# behaves identically in every consumer. See docs/contracts/package-updates.md.
{
  python3Packages,
}:

python3Packages.buildPythonApplication {
  pname = "package-updates";
  version = "1.0";
  src = ./.;
  format = "pyproject";
  nativeBuildInputs = [ python3Packages.setuptools ];

  pythonImportsCheck = [ "package_updates" ];

  meta = {
    description = "Batch runner for the fleet package-update contract";
    mainProgram = "update-packages";
  };
}
