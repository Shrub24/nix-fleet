# resolveBuildProfile: the one public scheduling API. Stage 1 turns
# canonical hosts/external builders plus a named profile into normalized
# BuilderSpec[]; stage 2 renders those specs into target forms
# (machines file, ssh config, known hosts, nix.buildMachines). Consumers
# never rebuild builder records by hand.
lib:
let
  inherit (lib)
    mapAttrsToList
    nameValuePair
    filterAttrs
    any
    filter
    ;
in
rec {
  # Stage 1: hosts + externalBuilders + profile name -> [ BuilderSpec ].
  # Unknown references fail closed by name. BuilderSpec is variant-free:
  # every field a renderer needs is resolved here.
  resolveBuildProfile =
    fleet: profileName:
    let
      profile =
        fleet.buildProfiles.${profileName}
          or (throw "fleet: buildProfile '${profileName}' does not exist; declared: ${lib.concatStringsSep ", " (builtins.attrNames fleet.buildProfiles)}");

      hostSpecs = mapAttrsToList (
        hostId: member:
        let
          host =
            fleet.hosts.${hostId}
              or (throw "fleet: profile '${profileName}' names fleet host '${hostId}' which does not exist");
          cap = (host.capabilities or { }).nixBuilder or { };
        in
        if !(cap.enable or false) then
          throw "fleet: profile '${profileName}' schedules host '${hostId}' which has capabilities.nixBuilder.enable = false"
        else
          {
            name = hostId;
            address = "${cap.endpoint.protocol or "ssh-ng"}://${host.tailscale.hostname}";
            hostName = host.tailscale.hostname;
            hostNames = if (host.hostNames or [ ]) != [ ] then host.hostNames else [ host.tailscale.hostname ];
            inherit (host) publicKey;
            systems = [ host.system ] ++ (cap.extraSystems or [ ]);
            sshUser = cap.endpoint.user or "nixbuild";
            sshKeyPath = null; # credential reference stays consumer-side
            sshOptions = { };
            maxJobs = if (member.maxJobs or null) != null then member.maxJobs else (cap.maxJobs or 1);
            speedFactor =
              if (member.speedFactor or null) != null then member.speedFactor else (cap.speedFactor or 1);
            supportedFeatures =
              if (member.supportedFeatures or null) != null then
                member.supportedFeatures
              else
                (cap.supportedFeatures or [ ]);
            mandatoryFeatures =
              if (member.mandatoryFeatures or null) != null then
                member.mandatoryFeatures
              else
                (cap.mandatoryFeatures or [ ]);
          }
      ) profile.hosts;

      externalSpecs = mapAttrsToList (
        extId: member:
        let
          ext =
            fleet.externalBuilders.${extId}
              or (throw "fleet: profile '${profileName}' names external builder '${extId}' which does not exist");
          bare = lib.last (
            lib.splitString "@" (lib.removePrefix "ssh-ng://" (lib.removePrefix "ssh://" ext.uri))
          );
        in
        {
          name = extId;
          address = ext.uri;
          hostName = bare;
          hostNames = if (ext.hostNames or [ ]) != [ ] then ext.hostNames else [ bare ];
          publicKey = ext.publicHostKey or null;
          inherit (ext) systems;
          sshUser = if (member.sshUser or null) != null then member.sshUser else (ext.sshUser or null);
          sshKeyPath = null;
          sshOptions = { };
          maxJobs = if (member.maxJobs or null) != null then member.maxJobs else 1;
          speedFactor =
            if (member.speedFactor or null) != null then member.speedFactor else (ext.speedFactor or 1);
          supportedFeatures = [ ];
          mandatoryFeatures = [ ];
        }
      ) profile.external;
    in
    hostSpecs ++ externalSpecs;

  # A profile schedules nothing -> almost certainly a mistake; fail closed.
  assertNonEmpty =
    profileName: specs:
    if specs == [ ] then
      throw "fleet: buildProfile '${profileName}' resolves to zero builders — empty profiles schedule nothing and are never what you want"
    else
      true;

  # Host entries for known-hosts: exactly the fleet hosts a profile requires.
  # Trust is a projection of the selection, never the whole inventory.
  profileHosts = fleet: specs: filterAttrs (id: _: any (spec: spec.name == id) specs) fleet.hosts;

  # Stage 2a: nix.buildMachines entries (NixOS option form).
  # Stage 2a: nix.buildMachines entries (NixOS option form). nixpkgs fields:
  # sshKey (not sshKeyPath), publicHostKey takes the base64 body.
  buildMachines =
    specs:
    map (
      spec:
      {
        hostName = spec.address;
        # Comma-joined: nix's machines-file parser accepts a system list.
        system = lib.concatStringsSep "," spec.systems;
        protocol = "ssh-ng";
        inherit (spec) sshUser;
        sshKey = spec.sshKeyPath;
        inherit (spec) maxJobs;
        inherit (spec) speedFactor;
        inherit (spec) supportedFeatures;
        inherit (spec) mandatoryFeatures;
        publicHostKey =
          if spec.publicKey == null then
            null
          else
            # nixpkgs wants the base64 body of the key line, not the full record.
            lib.elemAt (lib.splitString " " spec.publicKey) 1;
      }
      // lib.optionalAttrs (spec.sshOptions != { }) { inherit (spec) sshOptions; }
    ) specs;

  # Stage 2b: /etc/nix/machines text form.
  machinesFile =
    specs:
    lib.concatStringsSep "\n" (
      map (
        spec:
        let
          fields = value: if value == [ ] then "-" else lib.concatStringsSep "," value;
        in
        lib.concatStringsSep " " [
          spec.address
          (lib.concatStringsSep "," spec.systems)
          (if spec.sshKeyPath == null then "-" else spec.sshKeyPath)
          (toString spec.maxJobs)
          (toString spec.speedFactor)
          (fields spec.supportedFeatures)
          (fields spec.mandatoryFeatures)
        ]
      ) specs
    )
    + lib.optionalString (specs != [ ]) "\n";

  # Stage 2c: programs.ssh.knownHosts entries for exactly the selection.
  knownHosts =
    specs:
    builtins.listToAttrs (
      map (
        spec:
        nameValuePair "host-${spec.name}" {
          inherit (spec) hostNames publicKey;
        }
      ) (filter (spec: spec.publicKey != null) specs)
    );

  # Stage 2d: ssh client Host blocks for the selection.
  sshConfig =
    specs:
    lib.concatStringsSep "\n" (
      map (
        spec:
        lib.concatStringsSep "\n" (
          [ "Host ${spec.hostName}" ]
          ++ lib.optionals (spec.sshUser != null) [ "  User ${spec.sshUser}" ]
          ++ mapAttrsToList (key: value: "  ${key} ${value}") spec.sshOptions
        )
      ) specs
    );
}
