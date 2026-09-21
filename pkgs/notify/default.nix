{
  python3Packages,
}:

python3Packages.buildPythonApplication {
  pname = "notify";
  version = "1.0";
  src = ./.;
  format = "pyproject";
  nativeBuildInputs = with python3Packages; [ setuptools ];
  propagatedBuildInputs = with python3Packages; [ apprise ];

  meta = {
    description = "Notification CLI and systemd event handler sharing one dispatch library";
    mainProgram = "notify";
  };
}
