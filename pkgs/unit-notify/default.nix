{
  python3,
}:

python3.pkgs.buildPythonApplication rec {
  pname = "unit-notify";
  version = "1.0";
  format = "other";

  src = ./.;

  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 unit-notify.py $out/bin/unit-notify
    patchShebangs $out/bin/unit-notify
    runHook postInstall
  '';

  meta = {
    description = "systemd OnFailure/OnSuccess handler posting unit outcomes to the notification daemon";
    mainProgram = "unit-notify";
  };
}
