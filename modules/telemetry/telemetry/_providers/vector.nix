# Vector implementation of the contract's journald-ingest capability. Imported
# as a private module by flake.modules.nixos.telemetry — this is not a public
# aspect and adds no second host import. It ships this host's systemd journal to
# `services.telemetry.journald.sink.endpoint` over the backend's HTTP JSON-line
# API, with a bounded on-disk buffer plus persistent journal read checkpoints.
#
# Logs deliberately do not travel through the local OpenTelemetry collector:
# that pipeline is memory-only, so routing journald through it would advertise a
# durability it does not have. Vector's disk buffer only covers
# journal -> Vector -> backend; once a record is accepted by the backend,
# durability is the backend's business.
{
  config,
  lib,
  ...
}:
let
  telemetry = config.services.telemetry;
  cfg = telemetry.journald;

  # The capability selector, exactly as the collector adapter reads its own.
  servesJournaldIngest = telemetry.providers.journaldIngest == "vector";

  enabled = cfg.enable && servesJournaldIngest;

  # Vector rejects a disk buffer below ~256 MiB (268435488 bytes) at startup.
  diskBufferFloorBytes = 268435488;
  bufferBytes = cfg.buffer.maxSizeMb * 1048576;

  sinkName = "logs";
in
{
  imports = [ ../../../notifications/notify/_notify-events.nix ];

  config = lib.mkIf enabled {
    services.vector = {
      enable = true;
      # Reading the journal needs the systemd-journal group; the module's
      # DynamicUser + StateDirectory stay as they are.
      journaldAccess = true;
      settings =
        if cfg.sink.endpoint == null then
          throw "telemetry: journald shipping is enabled but services.telemetry.journald.sink.endpoint is not set; the host's journal has nowhere to go"
        else if bufferBytes < diskBufferFloorBytes then
          throw "telemetry: journald buffer.maxSizeMb=${toString cfg.buffer.maxSizeMb} is below Vector's disk-buffer floor (${toString diskBufferFloorBytes} bytes); use at least 257"
        else
          {
            # The unit's StateDirectory. Journal read checkpoints and the sink's
            # disk buffer both live here, so a restart resumes after the last
            # checkpoint instead of re-reading, and a buffered batch survives.
            data_dir = "/var/lib/vector";
            sources.journald = {
              type = "journald";
            }
            // lib.optionalAttrs (cfg.includeUnits != [ ]) { include_units = cfg.includeUnits; }
            // lib.optionalAttrs (cfg.excludeUnits != [ ]) { exclude_units = cfg.excludeUnits; };
            sinks.${sinkName} = {
              type = "http";
              inputs = [ "journald" ];
              uri = cfg.sink.endpoint;
              method = "post";
              # JSON-line: one event per line, no envelope — the backend's line
              # reader rejects or skips anything else.
              compression = "gzip";
              encoding.codec = "json";
              framing.method = "newline_delimited";
              # A health check would GET the ingest URL, which accepts no such
              # request; the sink reports failures itself.
              healthcheck.enabled = false;
              request.headers = {
                "VL-Stream-Fields" = lib.concatStringsSep "," cfg.sink.streamFields;
                "VL-Msg-Field" = "message";
                "VL-Time-Field" = "timestamp";
              };
              buffer = {
                type = "disk";
                max_size = bufferBytes;
                when_full = cfg.buffer.whenFull;
              };
            };
          };
    };

    # This provider owns the unit, so it registers the failure.
    services.notify.events.vector.failure = { };
  };
}
