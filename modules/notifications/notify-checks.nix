# Evaluation checks for the notify aspect.
#
# `notify-rendered-policy` reads the dispatch policy the aspect generates into
# /etc/notify — the rendered JSON, not the options it was generated from — so
# the two properties the generator owns fail here rather than at dispatch:
#
#   * a registered event's severity defaults per event kind (failure at
#     warning, success at info); only the rendered entry shows that the default
#     was applied;
#   * every enabled transport's rendered routing resolves: a non-empty `topics`
#     map and a `default_topic` naming one of its keys. A transport that cannot
#     resolve a topic refuses the notification, so an unresolvable default is a
#     dead dispatch path rather than a missing message.
{
  config,
  inputs,
  lib,
  ...
}:
let
  aspect = config.flake.modules.nixos.notify;

  transportFailures =
    routing: name:
    let
      transport = routing.${name} or null;
      topics = if transport == null then { } else transport.topics or { };
      default = if transport == null then null else transport.default_topic or null;
    in
    lib.optional (transport == null) "the rendered dispatch config declares no '${name}' transport"
    ++ lib.optional (
      transport != null && topics == { }
    ) "the rendered '${name}' transport declares no topics; nothing can be routed"
    ++
      lib.optional (transport != null && !(topics ? ${default}))
        "the rendered '${name}' transport has no default_topic naming one of its topics (default_topic = ${builtins.toJSON default}); a notification without an explicit topic would be refused at dispatch";
in
{
  perSystem =
    { pkgs, system, ... }:
    let
      # A throwaway host: the aspect, a registered unit with a real
      # implementation (the contract refuses a registration whose unit does not
      # exist), and a routing map with two topics so the default has to select a
      # key rather than being the only candidate.
      evaluated =
        (lib.nixosSystem {
          inherit system;
          modules = [
            inputs.sops-nix.nixosModules.sops
            aspect
            {
              system.stateVersion = "25.11";
              systemd.services.fixture-unit.script = "true";
              services.notify = {
                telegram = {
                  chatId = "-1000000000000";
                  topics = {
                    alerts = "7";
                    ops = "9";
                  };
                  defaultTopic = "ops";
                };
                ntfy = {
                  enable = true;
                  serverUrl = "http://127.0.0.1:8082";
                  topics = {
                    alerts = "alerts";
                    ops = "ops";
                  };
                  defaultTopic = "ops";
                };
                events.fixture-unit = {
                  failure = { };
                  success = { };
                };
              };
            }
          ];
        }).config;

      # The rendered artifacts, read as the bytes the daemon reads from
      # /etc/notify — not the values handed to a renderer.
      policy = builtins.fromJSON evaluated.environment.etc."notify/events.json".text;
      routing = builtins.fromJSON evaluated.environment.etc."notify/config.json".text;

      event = policy."fixture-unit" or null;

      # Severity defaults per event kind: failure alerts at warning, success at
      # info. The generator resolves them, so only the rendered entry can show
      # the default was applied.
      severityDefault = {
        failure = "warning";
        success = "info";
      };

      severityFailures = lib.concatMap (
        kind:
        let
          entry = if event == null then null else event.${kind} or null;
          rendered = if entry == null then null else entry.severity or null;
          expected = severityDefault.${kind};
        in
        lib.optional (entry == null)
          "the registered ${kind} event did not reach the rendered policy map; the registration/unit join regressed"
        ++
          lib.optional (entry != null && rendered != expected)
            "the rendered ${kind} event lost its per-kind severity default (${expected}); rendered ${builtins.toJSON rendered}"
      ) (builtins.attrNames severityDefault);

      failures =
        severityFailures
        ++ lib.concatMap (transportFailures routing) [
          "telegram"
          "ntfy"
        ];
    in
    {
      checks.notify-rendered-policy =
        if failures != [ ] then
          throw ("notify: " + lib.concatStringsSep "; " failures)
        else
          pkgs.runCommand "notify-rendered-policy-check" { } "touch $out";
    };
}
