{
  python3Packages,
}:

python3Packages.buildPythonApplication {
  pname = "notification-daemon";
  version = "1.0";
  src = ./.;
  format = "pyproject";
  nativeBuildInputs = with python3Packages; [ setuptools ];
  propagatedBuildInputs = with python3Packages; [
    apprise
    fastapi
    uvicorn
  ];
}
