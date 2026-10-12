# Host-local service endpoint shape. A local-service aspect publishes
# `services.<name>.localEndpoint` from its own listener, so the value a
# co-located consumer dials cannot drift from the port it binds. Nothing
# registers anywhere: the value exists only on hosts where the aspect is
# selected, so `null` means "this service does not run here".
#
# The dial address is always loopback. Listeners must therefore bind loopback
# or all interfaces; a publisher that binds one specific address declares that
# by asserting it, rather than publishing a loopback URL that cannot connect.
lib:
let
  loopback = "127.0.0.1";
in
{
  # mk { port; scheme ? "http"; basePath ? "/"; } -> endpoint record.
  # A root base path yields the bare origin, matching resolveEndpoint so
  # consumers append paths without a double slash.
  mk =
    {
      port,
      scheme ? "http",
      basePath ? "/",
    }:
    if
      !(builtins.elem scheme [
        "http"
        "https"
      ])
    then
      throw "localEndpoint: scheme must be http or https, not '${scheme}'"
    else if !(lib.hasPrefix "/" basePath) then
      throw "localEndpoint: basePath '${basePath}' must start with /"
    else
      let
        origin = "${scheme}://${loopback}:${toString port}";
      in
      {
        host = loopback;
        inherit port scheme basePath;
        url = if basePath == "/" then origin else origin + basePath;
      };

  type = lib.types.submodule {
    options = {
      host = lib.mkOption {
        type = lib.types.str;
        description = "Loopback address the record dials.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        description = "TCP port of the local listener.";
      };
      scheme = lib.mkOption {
        type = lib.types.enum [
          "http"
          "https"
        ];
        description = "URL scheme the listener speaks.";
      };
      basePath = lib.mkOption {
        type = lib.types.str;
        description = "Absolute URL path, preserved verbatim.";
      };
      url = lib.mkOption {
        type = lib.types.str;
        description = "Full URL a co-located consumer dials.";
      };
    };
  };
}
