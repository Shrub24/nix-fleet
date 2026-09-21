# Implementation packages for the mechanisms this repository owns. Owning the
# mechanism means owning its code; consumers place it, bind policy, and never
# reach into another repository for a package.
_: {
  perSystem =
    { pkgs, ... }:
    {
      packages = {
        notify = pkgs.callPackage ../../pkgs/notify { };
      };
    };
}
