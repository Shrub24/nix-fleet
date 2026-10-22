# Forces the derivations an all-systems flake check evaluates, so the source
# paths their evaluation copies are written to the store before it runs.
outputs:
let
  inherit (builtins)
    attrNames
    attrValues
    concatMap
    deepSeq
    isAttrs
    isList
    ;

  children =
    kind:
    concatMap (system: attrValues (outputs.${kind}.${system} or { })) (
      attrNames (outputs.${kind} or { })
    );

  hosts = map (host: host.config.system.build.toplevel) (
    attrValues (outputs.nixosConfigurations or { })
  );

  derivations =
    value:
    if isAttrs value && (value.type or "") == "derivation" then
      [ value.drvPath ]
    else if isAttrs value then
      concatMap derivations (attrValues value)
    else if isList value then
      concatMap derivations value
    else
      [ ];
in
deepSeq (concatMap derivations (
  children "checks"
  ++ children "devShells"
  ++ children "legacyPackages"
  ++ children "packages"
  ++ hosts
  ++ [ (outputs.hydraJobs or { }) ]
)) true
