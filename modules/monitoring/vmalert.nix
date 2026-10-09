# Rule evaluation on a host: vmalert evaluates the consumer's rules against the
# consumer's datasource and pushes firing alerts to the consumer's Alertmanager.
#
# Split: fleet = the mechanism — the validation below and the owned-unit failure
# registration; consumer = rules, thresholds, datasource, notifier, placement,
# and the alerting policy all of it serves. This aspect binds no instance and
# enables nothing: with no `services.vmalert.instances.*` bound, the host is
# inert.
#
# Fail closed: an enabled instance with no datasource to evaluate against, or no
# notifier to deliver to, is silent loss of alerting — refused by name here
# rather than discovered during the incident the alert was meant to announce.
# Both are named per instance, because which instance is broken is the whole
# question at 3am.
#
# The management endpoint is refused rather than defaulted, and that asymmetry is
# deliberate: `settings` is the consumer's per-instance CLI flag set, so a
# loopback default cannot be contributed there (a module that reads and rewrites
# `config.services.vmalert.instances` to add one recurses infinitely), and
# leaving vmalert's own `:8880` in place would publish rule and alert state on
# every interface — the opposite of this fleet's loopback-by-default surface
# (`services.vmalert.instances.<name>.settings."httpListenAddr"` is one line to
# bind, and exposure is then a deliberate act).
_: {
  flake.modules.nixos.vmalert =
    { config, lib, ... }:
    let
      enabledInstances = lib.filterAttrs (
        _name: instance: instance.enable
      ) config.services.vmalert.instances;

      # nixpkgs names the units from the instance key (`vmalert` for the legacy
      # top-level instance, `vmalert-<name>` otherwise). Re-derived rather than
      # read from `systemd.services`, because the registration has to be keyed
      # before those exist; the notify aspect's implemented-unit assertion
      # catches a drifted name, so this cannot silently register a phantom unit.
      unitName = name: "vmalert" + lib.optionalString (name != "") ("-" + name);

      instanceNames = builtins.attrNames enabledInstances;

      # `datasource.url` is nixpkgs' only required setting (nonEmptyStr, no
      # default), so "unbound" surfaces as an evaluation failure of the option
      # itself. tryEval observes that failure without raising it, which is what
      # turns it into our named refusal instead of nixpkgs' raw one.
      datasourceUnbound = builtins.filter (
        name: !(builtins.tryEval enabledInstances.${name}.settings."datasource.url").success
      ) instanceNames;
      notifierUnbound = builtins.filter (
        name: (enabledInstances.${name}.settings."notifier.url" or [ ]) == [ ]
      ) instanceNames;
      managementUnbound = builtins.filter (
        name: !(enabledInstances.${name}.settings ? "httpListenAddr")
      ) instanceNames;

      named = names: lib.concatMapStringsSep ", " (name: "'${name}'") names;
    in
    {
      imports = [ ../../lib/notify-contract.nix ];

      config = lib.mkIf (enabledInstances != { }) {
        assertions = [
          {
            assertion = datasourceUnbound == [ ];
            message = "vmalert: instance(s) ${named datasourceUnbound} are enabled without settings.\"datasource.url\" — vmalert would have no metrics source to evaluate rules against. Bind the Prometheus-compatible datasource (the consumer owns it; nix-fleet names no endpoint).";
          }
          {
            assertion = notifierUnbound == [ ];
            message = "vmalert: instance(s) ${named notifierUnbound} are enabled without settings.\"notifier.url\" — alerts would fire and reach nobody. Bind the Alertmanager URL (the alertmanager aspect defaults its listen address to 127.0.0.1).";
          }
          {
            assertion = managementUnbound == [ ];
            message = "vmalert: instance(s) ${named managementUnbound} are enabled without settings.\"httpListenAddr\" — vmalert's own default listens on every interface, publishing rule and alert state beyond this host. Bind the loopback address (\"127.0.0.1:8880\", a distinct port per instance), or an explicit address if you mean to serve it.";
          }
        ];

        # The instances are the consumer's; the units they generate are this
        # aspect's to observe. One failure registration per instance, so a
        # vmalert that stops evaluating rules is itself announced.
        services.notify.events = lib.mapAttrs' (name: _instance: {
          name = unitName name;
          value.failure = { };
        }) enabledInstances;
      };
    };
}
