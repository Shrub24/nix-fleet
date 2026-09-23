# Pure renderers over the fleet registry (modules/flake/registry.nix). Each
# turns typed records into one target form: Nix machines-file lines,
# known-hosts entries, ssh client Host blocks. No NixOS or flake-parts
# machinery here, so CI consumers can call these directly from a plain
# `let fleet = ...` binding (published as lib.registry).
lib: rec {
  # The store URI a builder connection dials: an external builder's explicit
  # URI, or ssh-ng:// plus the fleet host's tailscale machine hostname
  # (MagicDNS resolves bare names tailnet-wide).
  builderAddress =
    hostRegistry: builder:
    if (builder.uri or null) != null then
      builder.uri
    else
      "ssh-ng://${hostRegistry.${builder.host}.tailscale.hostname}";

  # The ssh host part of a builder address, for Host blocks and known-hosts:
  # scheme stripped, user@ stripped.
  builderHostName =
    hostRegistry: builder:
    let
      bare = lib.removePrefix "ssh-ng://" (
        lib.removePrefix "ssh://" (builderAddress hostRegistry builder)
      );
    in
    lib.last (lib.splitString "@" bare);

  # One nix machines-file line per builder. Comma-joins systems (upstream
  # parseMachines accepts that); "-" for empty feature lists and for the key
  # column when the builder relies on agent/default IdentityFile config.
  machinesLine =
    hostRegistry: _name: builder:
    let
      fields = value: if value == [ ] then "-" else lib.concatStringsSep "," value;
    in
    lib.concatStringsSep " " [
      (builderAddress hostRegistry builder)
      (lib.concatStringsSep "," (builder.systems or [ ]))
      (if (builder.sshKeyPath or null) == null then "-" else builder.sshKeyPath)
      (toString (builder.maxJobs or 1))
      (toString (builder.speedFactor or 1))
      (fields (builder.supportedFeatures or [ ]))
      (fields (builder.mandatoryFeatures or [ ]))
    ];

  machinesFile =
    hostRegistry: builders:
    lib.concatStringsSep "\n" (lib.mapAttrsToList (machinesLine hostRegistry) builders)
    + lib.optionalString (builders != { }) "\n";

  # programs.ssh.knownHosts entries: every registry host with a bound host key,
  # plus external builders that carry their own (fleet-host builders inherit
  # the host's key, so they never restate it).
  knownHosts =
    hostRegistry: builders:
    let
      hostEntries = lib.mapAttrs' (
        id: host:
        lib.nameValuePair "host-${id}" {
          inherit (host) hostNames publicKey;
        }
      ) (lib.filterAttrs (_id: host: host.publicKey != null) hostRegistry);
      builderEntries = lib.mapAttrs' (
        name: builder:
        lib.nameValuePair "builder-${name}" {
          hostNames =
            if (builder.hostNames or [ ]) != [ ] then
              builder.hostNames
            else
              [ (builderHostName hostRegistry builder) ];
          publicKey = builder.publicHostKey;
        }
      ) (lib.filterAttrs (_name: builder: (builder.publicHostKey or null) != null) builders);
    in
    hostEntries // builderEntries;

  # ssh client Host blocks for the given builders: long-build tuning applies to
  # every connection the registry schedules. User is rendered so non-NixOS
  # callers (a copied CI workflow on a runner) dial the configured user instead
  # of the local one.
  hostBlock =
    hostRegistry: builder:
    lib.concatStringsSep "\n" (
      [ "Host ${builderHostName hostRegistry builder}" ]
      ++ lib.optionals (builder.sshUser or null != null) [ "  User ${builder.sshUser}" ]
      ++ lib.mapAttrsToList (key: value: "  ${key} ${value}") (builder.sshOptions or { })
    );

  sshConfig =
    hostRegistry: builders:
    lib.concatStringsSep "\n" (lib.mapAttrsToList (_name: hostBlock hostRegistry) builders);
}
