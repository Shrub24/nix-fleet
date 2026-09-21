# Declaration-only registration contract for native systemd event
# notifications. Contributors write
#
#   services.notify-events.events.<unit>.failure.severity = "critical";
#
# on hosts where the notify aspect is co-selected; the aspect validates the
# target unit, renders the policy map, and attaches the native systemd
# OnFailure=/OnSuccess= hooks. The option lives inside the notify aspect: if
# notify is absent, a registration fails as an unknown option — an invalid
# composition, reported as such.
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
        type = lib.types.enum [
          "info"
          "success"
          "warning"
          "failure"
          "critical"
        ];
        default = "failure";
        description = "Notification severity. Defaults mirror the event; critical is an explicit escalation.";
      };

      topic = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Semantic ntfy topic override; null uses the daemon's tier default.";
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
  options.services.notify-events.events = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
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
