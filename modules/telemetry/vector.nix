# Vector journald realization. Composition selects the shipper, which sends this
# host's systemd journal to
# `services.telemetry.journald.sink.endpoint` over the backend's HTTP JSON-line
# API, with a bounded on-disk buffer plus persistent journal read checkpoints.
#
# Logs deliberately do not travel through the local OpenTelemetry collector:
# journald shipping is a separate capability with its own provider and its own
# binding, so a host that ships logs need not admit OTLP logs or run a collector
# at all. Vector's disk buffer only covers journal -> Vector -> backend; once a
# record is accepted by the backend, durability is the backend's business. (The
# OTLP path gained its own persistent exporter queues separately; that does not
# make routing journald through it the same design.)
#
# Delivery health is part of the log realization: while shipping, Vector
# exposes its own internal metrics on a loopback Prometheus endpoint and
# registers that target. A metrics realization may consume the dormant source.
_: {
  flake.modules.nixos.telemetry-vector =
    {
      config,
      lib,
      ...
    }:
    let
      telemetry = config.services.telemetry;
      cfg = telemetry.journald;

      # Composition selects this realization; `journald.enable` controls whether
      # this optional workload has been configured.

      # Vector rejects a disk buffer below ~256 MiB (268435488 bytes) at startup.
      diskBufferFloorBytes = 268435488;
      bufferBytes = cfg.buffer.maxSizeMb * 1048576;

      sinkName = "logs";

      # Vector's own internal metrics, exported so the selected scrape provider
      # collects the log lane's delivery health (buffer occupancy, send errors,
      # dropped records) through the ordinary scrape registration — not through
      # a second, log-carrying sink. 9598 is Vector's documented port for this
      # sink and is unused by the rest of the baseline.
      healthPort = 9598;
      healthJob = "vector-health";

      # The listener and registration belong to this realization, not to a
      # metrics destination. A later-composed metrics realization can consume it.
    in
    {
      imports = [
        ../../lib/telemetry-contract.nix
        ../notifications/notify/_notify-events.nix
      ];

      key = "nix-fleet/telemetry-vector";
      config = lib.mkMerge [
        {
          services.telemetry.journald.enable = true;
          services.vector = {
            enable = true;
            # Reading the journal needs the systemd-journal group; the module's
            # DynamicUser + StateDirectory stay as they are.
            journaldAccess = true;
            settings =
              if bufferBytes < diskBufferFloorBytes then
                throw "telemetry: journald buffer.maxSizeMb=${toString cfg.buffer.maxSizeMb} is below Vector's disk-buffer floor (${toString diskBufferFloorBytes} bytes); use at least 257"
              else
                {
                  # The unit's StateDirectory. Journal read checkpoints and the sink's
                  # disk buffer both live here, so a restart resumes after the last
                  # checkpoint instead of re-reading, and a buffered batch survives.
                  data_dir = "/var/lib/vector";
                  sources = {
                    journald = {
                      type = "journald";
                      # Vector's own default, stated because it is a scope
                      # decision: a restart resumes from the saved checkpoint,
                      # but records of an earlier boot that were never read are
                      # not replayed, even while journald still holds them.
                      current_boot_only = true;
                    }
                    // lib.optionalAttrs (cfg.includeUnits != [ ]) { include_units = cfg.includeUnits; }
                    // lib.optionalAttrs (cfg.excludeUnits != [ ]) { exclude_units = cfg.excludeUnits; };
                  }
                  // {
                    internal_metrics = {
                      type = "internal_metrics";
                    };
                  };
                  sinks = {
                    ${sinkName} = {
                      type = "http";
                      inputs = [ "journald" ];
                      uri =
                        if cfg.sink.endpoint == null then
                          throw "telemetry: journald shipping is enabled but services.telemetry.journald.sink.endpoint is not set; the host's journal has nowhere to go"
                        else
                          cfg.sink.endpoint;
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
                  }
                  // {
                    ${healthJob} = {
                      type = "prometheus_exporter";
                      # Only its own internal metrics: this is a health surface,
                      # never a second path for journal records.
                      inputs = [ "internal_metrics" ];
                      address = "127.0.0.1:${toString healthPort}";
                      # Pins the `vector_*` prefix the delivery metrics are
                      # documented under.
                      default_namespace = "vector";
                    };
                  };
                };
          };

          # This provider owns the unit, so it registers the failure.
          services.notify.events.vector.failure = { };
        }
        {
          # The provider owns its own health listener, so it also registers the
          # scrape: the consumer never re-derives the port, and a moved listener
          # cannot leave a stale scrape behind.
          services.telemetry.scrape.${healthJob} = {
            target = "127.0.0.1";
            port = healthPort;
            labels.instance = "${config.networking.hostName}:vector";
          };
        }
      ];
    };
}
