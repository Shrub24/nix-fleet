# Design

## Decision 1 — derive the fleet revision instead of passing one

`job.workflow_repository` and `job.workflow_sha` are the repository and commit of
the file that defines the executing job; for a called workflow they name the
called file. GitHub's own documentation uses exactly this pair to check out the
revision that defines a reusable workflow. Resolution is therefore
`github:<job.workflow_repository>@<job.workflow_sha>#packages.<runner_system>.ci-coordinator-<profile>`.

A `fleet_ref` input, a re-exported builder set, or a published metadata artifact
with its own version contract would each be a second thing to keep in step with
the workflow that consumes it. Deriving the revision makes disagreement
unrepresentable rather than merely checkable.

Constraint found while verifying: the `job` context is available inside a job's
steps and not at job level, so any decision at job level must key off `inputs`.
The context is unavailable on GHES; fleet CI does not run there.

## Decision 2 — the coordinator owns builders and substituters, nothing else

`niks3-action` requires a trusted user for `post-build-hook`, and installs the
hook in its own user-level Nix configuration, which it prepends so that it
overrides `/etc/nix/nix.conf`. A coordinator that also set `trusted-users` would
shadow the installer's grant and silently stop publication — an empty cache
rather than an error. Hence the split: coordinator owns `builders`,
`builders-use-substitutes`, `extra-substituters`, `extra-trusted-public-keys`;
the installer owns trust; the publishing action owns the hook; the workflow owns
runner policy (`max-jobs`). The artifact's build enforces it.

`extra-` forms are mandatory for the same reason: user-level configuration wins
per setting, and an additive directive merges instead of replacing.

## Decision 3 — conventional install paths, no self-reference

A derivation cannot embed its own store path, so the rendered `nix.conf` names
`/etc/nix/machines` rather than a path inside the artifact, and the installer
copies files from the artifact's own directory at runtime. Content references
conventional paths; the installer may use `dirname "$0"`.

## Decision 4 — the SSH identity is written by the workflow, not the artifact

The identity is a secret and the artifact is a published, world-readable
derivation. The workflow writes it to `/etc/nix/builder_ed25519`, `0640`
`root:runner`, and the rendered `ssh_config` names that path. `0640` rather than
`0600` means the identity works whichever context opens the builder session, and
each run's report states which one did — replacing an inference with a
measurement on every run.

Measured while establishing this: fleet CI reaches builders over plain SSH
(`sshd` on port 22) authenticated by the key, not Tailscale SSH, and the
coordinator's own build log contains no `building … on 'ssh-ng://'` lines even
when it plainly does delegate (an ARM runner realised an x86_64 VM test). Remote
use is visible only builder-side, in `nix-daemon`'s `accepted connection … user
nixbuild (trusted)` lines and the derivation logs under `/nix/var/log/nix/drvs`.

## Decision 5 — no daemon restart

Every setting the coordinator writes is client-side and re-read per invocation;
the installer restarts the daemon when it configures the machine, and nothing
after that needs one. The install step reads `builders` back through the
installed configuration, so "no restart needed" is observed rather than assumed.
Presenting a restart as the mechanism would also suggest the daemon dials the
builders, which it does not.

## Decision 6 — reporting instead of a pre-flight veto

The previous workflow dialled every builder and failed the job when a requested
system had nowhere to build. That converts a transient builder outage into a
blocked pipeline, and duplicates over time what fleet telemetry does better. The
report runs unconditionally, including after a failed build, and records the
effective `builders`, per-builder SSH from both contexts, and the number of
derivations realised.

Accepted cost: nothing now proves a builder _built_ anything, so a silent local
fallback shows up only as an implausibly small realisation count and a cache that
does not warm. The answer belongs in metrics, not in a refusal.

## Decision 7 — the bootstrap cache is a workflow literal with a check

The coordinator is fetched through the cache, so the cache coordinates cannot
come from the coordinator. They are therefore the only fleet facts stated in the
workflow, and `tests/ci/build_workflow_check.py` asserts them equal to
`packages.<system>.cache-substituter-url` and `cache-public-key`. A cache move
fails the build instead of silently falling back to local builds.

## Decision 8 — `profile` replaces `builder_attr`; a bundle still exists

`profile` names what the coordinator renders. The bare bundle package stays
because it is the input the coordinator projects, not a parallel interface.
`nix-homelab`'s pinned reference predates the rename and keeps working until
bumped; that bump must carry the rename.

## Superseded

The earlier model — install `.#packages.<profile>` from the caller's flake and
resolve Tailscale and cache coordinates from that flake — is superseded, not
deleted: it is why the coordinator exists.
