# Hosts contract — machine identity and trust

`flakeModules.registry` declares the typed inventory for machines the fleet
controls. It is **identity only**: who a host is, not what it runs. No
compositions, no deploy records, no policy — those stay consumer-side.

## What the consumer declares

At flake level (top of the consumer's mkFlake module set):

```nix
imports = [ inputs.nix-fleet.flakeModules.registry ];

fleet.hosts.home-forge = {
  system = "x86_64-linux";              # target system; null = builder-only identity
  tailscale.hostname = "home-forge";    # MagicDNS resolves this tailnet-wide
  hostNames = [ "home-forge" ];         # names for the known-hosts entry (aliases welcome)
  publicKey = "ssh-ed25519 AAAA...";    # the host's SSH host key
};
```

- `tailscale.hostname` is the address fleet connections dial. MagicDNS
  resolves bare machine names inside the tailnet; no FQDN machinery, no
  tailnet suffix in nix-fleet. If a consumer needs full DNS names for its own
  purposes (web policies, ACLs), it derives them locally.
- `publicKey` is deliberately nullable so an identity can be declared before
  its host key is bound; the trust renderer skips keyless hosts.

## What the consumer gets

### Trust (additive, always on)

Any host composition importing the constructed aspect gets, for every
registry host with a bound key:

- `programs.ssh.knownHosts` entries
- `programs.ssh.extraConfig` Host blocks with conventional long-build tuning
  (keepalives, ed25519-only, IPQoS) — overridable per builder via
  `fleet.builders.<name>.sshOptions`

This is correct by construction: a host in the registry is a host you
declared you control, so trusting its key is definitionally safe. **Trust
never implies use** — being in the registry does not make a host a builder
that gets scheduled, a substituter, or a deploy target. Those are separate
decisions (see builders.md; substituter catalogs remain consumer policy).

Consumer-side extras merge additively:

```nix
services.fleet-builders.extraKnownHosts.<alias> = {
  hostNames = [ "github.com" ];         # non-fleet hosts, same mechanism
  publicKey = "ssh-ed25519 AAAA...";
};
```

### Deriving instead of duplicating

Homelab's own host registry should **derive from this one** (system,
tailscale hostname, host key) rather than restate them — one hostname/SSH
key/system SSOT across the fleet. nix-homelab keeps compositions, placement,
and everything NixOS-materialization-shaped. Dotfiles may reference the same
identities for its fleet machines and keep local identity for personal
non-fleet hosts; the registry is allowed to be partial.

## Relationship to builders

Host identity is the substrate builders reference: a builder entry points at
a `fleet.hosts` key and inherits its address and host key. See
[builders.md](builders.md).
