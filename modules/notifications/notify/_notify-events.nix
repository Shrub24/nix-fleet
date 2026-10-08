# Registration contract for native systemd event notifications. Contributors
# write
#
#   services.notify.events.<unit>.failure.severity = "critical";
#
# on hosts where the notify aspect is co-selected; the aspect validates the
# target unit, renders the policy map, and attaches the native systemd
# OnFailure=/OnSuccess= hooks.
#
# Registering aspects import THIS fragment, so the option is declared wherever a
# registration is written — including on a host that never selects the notify
# aspect. A registration is therefore INERT BY DESIGN without notify: it
# evaluates, it is visible in the merged configuration, and it produces no hook
# and no dispatcher, because attaching hooks is the notify aspect's job alone.
# Silence here is deliberate rather than an accident of evaluation: the fleet
# baseline requires notify on every managed host, and checking that a host's
# registrations are realized is the consumer composition's job — not something
# this declaration-only fragment can enforce. (An enable flag or a
# realized-marker guard would trade an inert registration for a second
# enablement dialect and a duplicate-ownership hazard; the notify aspect is the
# one place a unit gets its hooks.)
#
# Success events fire when a unit enters the inactive state — meaningful for
# scheduled/oneshot jobs whose completion is a semantic event, but also fired
# on deliberate stops of long-running daemons; reserve success for jobs where
# clean completion is worth announcing.
#
# RestartMode=direct skips OnFailure=/OnSuccess= during automatic restarts;
# "notify me on failure" therefore means "notify me when systemd exposes a
# failure transition", not "notify on every internal process crash".
{
  lib,
  ...
}:
let
  eventPolicyType = lib.types.submodule {
    options = {
      severity = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.enum [
            "info"
            "warning"
            "critical"
          ]
        );
        default = null;
        description = ''
          Notification severity: info | warning | critical. Null defaults per
          event kind — `failure` alerts at warning, `success` at info — so
          "failure" and "success" are event names, never severities.
        '';
      };

      topic = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Semantic ntfy topic override — routing declared by use case, resolved
          per transport (explicit topic, else the deployment's single default
          topic). Null uses that default.
        '';
      };

      journalLines = lib.mkOption {
        type = lib.types.int;
        default = 50;
        description = "Journal lines from the triggering invocation to include; 0 sends title and result only.";
      };

      context = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Include SERVICE_RESULT / EXIT_CODE / EXIT_STATUS in the message body.";
      };

      title = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Notification title override; null renders \"<unit> <event>\".";
      };
    };
  };
in
{
  options.services.notify.events = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          fromPackage = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              The unit comes from a systemd.packages entry (unit file provided
              by a package, overrides land as drop-ins). Such registrations are
              exempt from the implemented-unit check, which only sees
              option-level definitions. The unit must actually exist in a
              package — no aspect validates that; a typo fails at boot, not
              evaluation.
            '';
          };

          failure = lib.mkOption {
            type = lib.types.nullOr eventPolicyType;
            default = null;
            description = "Notify when the unit enters the failed state. Null = not registered.";
          };

          success = lib.mkOption {
            type = lib.types.nullOr eventPolicyType;
            default = null;
            description = "Notify when the unit enters the inactive state cleanly. Null = not registered.";
          };
        };
      }
    );
    default = { };
    description = "Per-unit notification policy for native systemd unit outcomes.";
  };
}
