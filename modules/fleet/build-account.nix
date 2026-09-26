# The builder-side dispatch account: isolated dial-in identity for remote
# Selection is enablement.
# build dispatch — no login shell, empty authorized keys by default. This is
# the mechanism half of the old realization; the fleet convention is that
# remote coordinators dial builder hosts as this account (see
# fleet.hosts.<id>.capabilities.nixBuilder.endpoint.user). Its authorized
# keys are consumer policy: the aspect owns the identity, the consumer owns
# who may use it.
_: {
  flake.modules.nixos.build-account =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      options.services.build-account = {
        name = lib.mkOption {
          type = lib.types.str;
          default = "nixbuild";
          description = "Account name. Rename only when a consumer needs a differently-scoped identity; the default is the fleet convention (endpoint.user defaults match it).";
        };
      };

      config = {
        users.users.${config.services.build-account.name} = {
          isSystemUser = true;
          group = config.services.build-account.name;
          description = "Fleet remote-build dispatch account";
          # ssh-ng remote store needs a working shell to execute the remote
          # nix command; the shadow default is not. Restrict via the
          # authorized key's command= / restrictions, not by removing the shell.
          shell = lib.getExe pkgs.bashInteractive;
          useDefaultShell = false;
          home = "/var/lib/${config.services.build-account.name}";
          createHome = true;
          openssh.authorizedKeys.keys = [ ];
        };
        users.groups.${config.services.build-account.name} = { };
      };
    };
}
