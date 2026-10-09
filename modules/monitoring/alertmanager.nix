# Alert grouping and delivery on a host: Alertmanager receives firing alerts
# (from vmalert and anything else that speaks its API), groups them, and routes
# each group to the consumer's receivers.
#
# Split: fleet = the mechanism — the loopback default and the owned-unit failure
# registration; consumer = the whole `configuration` (route tree, receivers,
# grouping, inhibition, recipients) and the alerting policy behind it. The
# aspect enables nothing: a host that has not bound
# `services.prometheus.alertmanager.enable` is inert, and the consumer owns that
# binding along with the configuration it requires.
#
# Secret-bearing receiver values never belong in the store: `configuration` is
# world-readable, so a bot token or credentialed webhook URL goes into
# `services.prometheus.alertmanager.environmentFile` (a sops-nix rendered file)
# and is referenced from `configuration` as `$VAR_NAME`, which the nixpkgs
# module substitutes at unit start. One consequence worth knowing before it
# bites: the `checkConfig` default validates the rendered configuration with
# `amtool` at build time, which cannot see environment values — a configuration
# whose required fields all come from the environment must set
# `checkConfig = false` and take that check on the host instead.
_: {
  flake.modules.nixos.alertmanager =
    { config, lib, ... }:
    {
      imports = [ ../../lib/notify-contract.nix ];

      config = {
        services.prometheus.alertmanager = {
          # nixpkgs listens on every interface by default. Alert delivery is a
          # loopback conversation between this host's rule evaluator and this
          # host's notifier, so the remote surface is off unless a consumer asks
          # for it (mkDefault: an explicit value wins, and exposure is then a
          # deliberate act rather than a default).
          listenAddress = lib.mkDefault "127.0.0.1";
          # `checkConfig`, `port`, `environmentFile`, and `configuration` stay
          # exactly as nixpkgs declares them: the configuration is the
          # consumer's, and its validity is the consumer's binding to get right.
        };

        # This aspect owns the unit when the consumer enables it, so it
        # registers the failure: an Alertmanager that dies is every alert it was
        # routing. `optionalAttrs` (not `mkIf`) keeps the registration a plain,
        # instance-independent definition.
        services.notify.events = lib.optionalAttrs config.services.prometheus.alertmanager.enable {
          alertmanager.failure = { };
        };
      };
    };
}
