# VictoriaMetrics vmagent implementation of the contract's Prometheus scrape
# capability. Imported as a private module by flake.modules.nixos.telemetry —
# this is not a public aspect and adds no second host import. It renders
# `services.telemetry.scrape` into nixpkgs' `services.vmagent` and the selected
# metrics fanout into vmagent's own `-remoteWrite.*` arguments.
#
# vmagent is a scrape-and-forward agent: it speaks Prometheus remote write and
# nothing else, so every destination the contract's metrics pipeline selects
# must be `prometheus-remote-write`. One it cannot write to is a named failure,
# never a silently narrowed fanout.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  telemetry = config.services.telemetry;

  # The capability selector, exactly as the collector adapter reads its own.
  servesPrometheusScrape = telemetry.providers.prometheusScrape == "vmagent";

  # A scrape source the contract registered, in Prometheus scrape-config shape.
  # The registration name is the job name. `services.vmagent.checkConfig` (left
  # at its default) runs the rendered YAML through the real binary at build
  # time, so a malformed registration fails the build rather than the unit.
  scrapeConfigs = lib.mapAttrsToList (name: source: {
    job_name = name;
    scrape_interval = source.interval;
    metrics_path = source.metricsPath;
    inherit (source) scheme;
    static_configs = [
      {
        targets = [ "${source.target}:${toString source.port}" ];
        inherit (source) labels;
      }
    ];
  }) telemetry.scrape;
  hasScrapes = scrapeConfigs != [ ];

  # Scrape work is this provider's business only when it is the selected scrape
  # provider and something registered a source.
  scrapeWork = servesPrometheusScrape && hasScrapes;

  metricsDestinations = telemetry.resolvedPipelines.metrics;
  unwritable = builtins.filter (
    name: telemetry.destinations.${name}.protocol != "prometheus-remote-write"
  ) metricsDestinations;
  destinationWithProtocol = name: "'${name}' (${telemetry.destinations.${name}.protocol})";

  # vmagent expands `%{ENV_VAR}` in its arguments BEFORE parsing them, and its
  # `-remoteWrite.*` flags are comma-separated positional arrays whose elements
  # are `^^`-separated header lists. A value carrying one of these characters is
  # therefore not data, it is structure: an expanded `,` adds an array element
  # and shifts every later element onto the NEXT destination, so a credential
  # can be delivered somewhere it was never bound. Literal values are visible
  # here and fail the build (`literalFailures` below); a secret's value exists
  # only at start, so the unit checks it there (`secretGuard`) rather than
  # trusting the alphabet a credential happens to use.
  unsafeChars = [
    ","
    "^"
    "["
    "]"
    "{"
    "}"
    "("
    ")"
    "'"
    "\""
    "\n"
    "\r"
  ];
  hasUnsafe = value: builtins.any (char: lib.hasInfix char value) unsafeChars;

  # `tr -d` takes octal escapes, so the guard's character set is DERIVED from
  # the list above: the build-time and start-time rules cannot drift apart.
  charToOctal =
    char:
    let
      code = lib.strings.charToInt char;
      hundreds = code / 64;
      tens = (code - hundreds * 64) / 8;
      ones = code - hundreds * 64 - tens * 8;
    in
    "\\${toString hundreds}${toString tens}${toString ones}";
  octalSet = lib.concatMapStrings charToOctal (
    lib.stringToCharacters (lib.concatStrings unsafeChars)
  );

  # vmagent expands `%{ENV_VAR}` placeholders in its command-line flags itself —
  # its own documented substitution syntax, not OTel's `${env:...}` — so an
  # argument carries a reference and the credential stays in the unit
  # environment: never in the Nix store, never in argv.
  envName = id: "VMAGENT_${id}";

  # The credential is only known once the unit's environment is loaded, which is
  # also the last moment before vmagent parses its arguments — so that is where
  # an unrepresentable value is refused. Deleting every character vmagent treats
  # as structure is the test: a value they cannot change cannot move a header.
  # A trailing newline is caught as well, because the command substitution drops
  # it while the variable keeps it.
  secretGuard = pkgs.writeShellScript "vmagent-secret-guard" ''
    set -eu
    status=0
    for name in "$@"; do
      eval "value=\''${$name-}"
      stripped=$(printf '%s' "$value" | ${pkgs.coreutils}/bin/tr -d '${octalSet}')
      if [ "$stripped" != "$value" ]; then
        echo "telemetry: $name contains a character that vmagent's remote-write argument parser treats as structure (comma, caret, bracket, brace, parenthesis, quote or newline); refusing to start rather than risk sending a credential to a destination that was not given one" >&2
        status=1
      fi
    done
    exit "$status"
  '';
  secretReady =
    id:
    (telemetry.secretFiles.${id} or null) != null && builtins.pathExists telemetry.secretFiles.${id};
  headerEntry =
    name:
    lib.concatStringsSep "^^" (
      lib.mapAttrsToList (
        headerName: header:
        if !secretReady header.secret then
          throw "telemetry: destination '${name}' header references unknown or unbound secret '${header.secret}'"
        else
          "${headerName}: ${header.prefix}%{${envName header.secret}}"
      ) telemetry.destinations.${name}.headers
    );

  # One entry per destination the metrics pipeline selects, in pipeline order:
  # vmagent's `-remoteWrite.*` array flags are positional, so this order is what
  # aligns each URL with its own disk bound and its own headers.
  remoteWriteTargets = map (name: {
    url = telemetry.destinations.${name}.endpoint;
    headers = headerEntry name;
  }) metricsDestinations;

  # The file-based queue lives under the unit's StateDirectory (persistent
  # across reboots) and is bounded per destination. On overflow vmagent drops
  # the OLDEST buffered data to make room, so this is bounded durability — a
  # long outage past the bound loses samples — never a lossless promise.
  queueBytes = 1024 * 1024 * 1024;
  hasHeaders = builtins.any (target: target.headers != "") remoteWriteTargets;

  # `mkBefore`: a consumer's plain `services.vmagent.extraArgs` merges after
  # these, so an explicit scalar override (the disk bound, the queue path) wins
  # while these arguments stay in place.
  vmagentArgs =
    map (target: "-remoteWrite.url=${target.url}") remoteWriteTargets
    ++ [
      "-remoteWrite.tmpDataPath=%S/vmagent/remote_write_tmp"
      # Management/inspection endpoint: loopback only, no firewall rule.
      "-httpListenAddr=127.0.0.1:8429"
    ]
    ++ map (_: "-remoteWrite.maxDiskUsagePerURL=${toString queueBytes}") remoteWriteTargets
    ++ lib.optionals hasHeaders (
      map (target: "-remoteWrite.headers=${target.headers}") remoteWriteTargets
    );

  referencedSecretIds = lib.unique (
    lib.concatMap (
      name: map (header: header.secret) (lib.attrValues telemetry.destinations.${name}.headers)
    ) metricsDestinations
  );
  boundSecretIds = builtins.filter secretReady referencedSecretIds;
  secretsRegistered = boundSecretIds != [ ];

  # Literal values the adapter renders into its own argument array, so an
  # unrepresentable one can be refused at build time rather than at start.
  literalFailures = lib.concatMap (
    name:
    let
      destination = telemetry.destinations.${name};
      headerFailures = lib.concatMap (
        headerName:
        let
          header = destination.headers.${headerName};
        in
        lib.optional (hasUnsafe headerName) "destination '${name}' header name '${headerName}'"
        ++ lib.optional (hasUnsafe header.prefix) "destination '${name}' header '${headerName}' prefix"
      ) (builtins.attrNames destination.headers);
    in
    lib.optional (hasUnsafe destination.endpoint) "destination '${name}' endpoint '${destination.endpoint}'"
    ++ headerFailures
  ) metricsDestinations;
  # The argument also interpolates the secret's own ID (`%{VMAGENT_<id>}`). That
  # is safe without a check here: the telemetry contract admits only letters,
  # digits and underscores as secret IDs, a subset of what vmagent treats as
  # structure, so no admissible id can move a header. (That rule currently lives
  # in the OTel provider's `validSecretIds`, which evaluates for every telemetry
  # host; moving it into `_contract.nix`, where the naming space is declared,
  # would be the tidier home.)
  guardNames = map envName boundSecretIds;

  # All three mistakes fail closed by name; none leaves a unit behind that would
  # push scraped metrics somewhere the contract never selected.
  fanoutOk = metricsDestinations != [ ] && unwritable == [ ] && literalFailures == [ ];
in
{
  imports = [ ../../../notifications/notify/_notify-events.nix ];

  config = lib.mkMerge [
    {
      assertions = lib.optionals scrapeWork [
        {
          assertion = metricsDestinations != [ ];
          message = "telemetry: ${toString (builtins.length scrapeConfigs)} scrape source(s) are registered but the metrics pipeline has no destination to carry them";
        }
        {
          assertion = unwritable == [ ];
          message = "telemetry: the metrics pipeline selects ${
            lib.concatMapStringsSep ", " destinationWithProtocol unwritable
          } for metrics, which the scrape provider vmagent cannot write to — vmagent speaks prometheus-remote-write only. Repoint those destinations or select services.telemetry.providers.prometheusScrape = \"otel-collector\".";
        }
        {
          assertion = literalFailures == [ ];
          message = "telemetry: the metrics pipeline selects values vmagent's argument parser would treat as structure — ${lib.concatStringsSep "; " literalFailures} — because its remote-write arguments are comma-separated arrays: a comma, caret, bracket, brace, parenthesis, quote or newline would move a header onto another destination. Change the value or select services.telemetry.providers.prometheusScrape = \"otel-collector\".";
        }
      ];
    }
    (lib.mkIf (scrapeWork && fanoutOk) {
      services.vmagent = {
        enable = true;
        prometheusConfig.scrape_configs = scrapeConfigs;
        extraArgs = lib.mkBefore vmagentArgs;
      };

      # The queue and its unclean-shutdown marker are state, not cache: `%S`
      # expands to this StateDirectory's root.
      systemd.services.vmagent.serviceConfig = {
        StateDirectory = "vmagent";
      }
      // lib.optionalAttrs secretsRegistered {
        EnvironmentFile = [ config.sops.templates."vmagent.env".path ];
        # `-remoteWrite.headers` is positional, so a secret that would change how
        # vmagent parses its arguments has to stop the unit rather than be
        # forwarded with whatever alignment results.
        ExecStartPre = [ "${secretGuard} ${lib.escapeShellArgs guardNames}" ];
      };

      # This provider owns the unit, so it registers the failure.
      services.notify.events.vmagent.failure = { };

      sops.secrets = lib.genAttrs (map (id: "vmagent/${id}") boundSecretIds) (
        name:
        let
          id = lib.removePrefix "vmagent/" name;
        in
        {
          sopsFile = telemetry.secretFiles.${id};
          key = telemetry.secretKeys.${id};
          restartUnits = [ "vmagent.service" ];
        }
      );
      sops.templates."vmagent.env" = lib.mkIf secretsRegistered {
        content =
          lib.concatMapStringsSep "\n" (
            id: "${envName id}=${config.sops.placeholder."vmagent/${id}"}"
          ) boundSecretIds
          + "\n";
        restartUnits = [ "vmagent.service" ];
      };
    })
  ];
}
