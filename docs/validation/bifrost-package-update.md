# Bifrost package-update acceptance

## Candidate and provenance

- Baseline snapshot: `b0ec1dc3d9dd46090e73955eb9543d745ac4264e` (integrated, unpublished working copy).
- Evaluated nixpkgs: `151fa4e8ddfdd8dd25d945ad94ed54a13de9f6e4`.
- Updater: nix-update 1.16.0; Go: 1.27.1; packaged Nix: 2.35.2.
- Transport update: 2.2.5 → 2.2.6.
- Selected tag: `transports/v2.2.6`; resolved commit: `8b4fce4f1709d66f9208d02f50552da522535f9e`.
- Source hash: `sha256-vgdsNg48Cd4qoOwFyQ9ahnC6darTyAGV4/LkQSiBXzk=`.
- Go vendor hash: `sha256-y9q3wdnWEfKekZWVrmbL+bvomWLNAmydx2ld08C2D5Y=`.
- UI npm hash was refreshed and remained `sha256-cOswnT4ZahWX66h9oiw4t3r5GZeOH/yjbnTCAsjVgnw=`.

Default release discovery was checked separately: 2,314 upstream tags yielded
2.2.6 as the latest stable transport release. Unrelated component tags and
prereleases are excluded by the offline policy tests.

## Shared entry point

An isolated copy of the baseline ran:

```console
BIFROST_UPDATE_VERSION=2.2.6 nix run .#update-packages -- bifrost
```

The app dispatched the standard package update script successfully (exit 0).
A source-file manifest showed only `pkgs/bifrost/default.nix` changed: version,
upstream commit/hash and Go vendor hash. The lockfile and UI hash remained
unchanged. Host and derived Voyage-plugin versions both evaluate to 2.2.6.

nix-update also creates a `result` symlink to its generated update script;
that build artifact is distinguished from source-file changes. The first
manifest comparison included this symlink and was corrected to compare
regular source files, not reported as an extra package edit.

## Gates

| Gate                                                 | Result                                                                |
| ---------------------------------------------------- | --------------------------------------------------------------------- |
| Offline Bifrost release/update policy                | PASS: 5 tests                                                         |
| Shared runner and minimal consumer checks            | PASS: focused native builds                                           |
| Missing-output and swallowed-failure mutations       | PASS: both detected                                                   |
| Actual update through the shared app                 | PASS: exit 0, scoped source diff                                      |
| Same-target repeated refresh                         | PASS: empty additional source diff                                    |
| Updated gateway/UI startup                           | PASS: native check built                                              |
| Updated Voyage plugin load and request normalization | PASS: authenticated mock requests and observed normalized bodies      |
| Updated governance/CEL module runtime                | PASS: authenticated routing/governance, anonymous refusal and restart |
| All-system evaluation                                | PASS: final tree, both systems                                        |
| Fresh-store evaluation, IFD disabled                 | PASS: final tree in new empty store, both systems                     |
| Final formatting and complete native suite           | PASS: all 18 final native checks                                      |

The first runtime gates exposed two 2.2.6 authentication changes: the
management API needs setup/admin authentication, and fresh deployments require
inference credentials. The fixtures now use a test-only setup token and a
virtual key scoped to the two mock provider/model pairs; authentication was not
disabled. Both corrected runtime gates pass. Consumer migration requirements
are documented in the Bifrost contract.

The accepted candidate is retained only after the runtime and complete native
gates pass. Final-tree empty-store evaluation also passes. ARM was evaluated,
not built. This experiment does not deploy or modify either consumer.

## Accepted runtime outputs

- `checks.x86_64-linux.bifrost-startup`: `/nix/store/1bx05jkfgk9hck5hiizc7bq38ajiqvsh-bifrost-startup-check`.
- `checks.x86_64-linux.bifrost-voyage-plugin`: `/nix/store/xg78ray72xxsg3c1c6rihwks2rcfwg9h-bifrost-voyage-plugin-check`.
- `checks.x86_64-linux.bifrost-module`: `/nix/store/d5m3xxicyjg37faafbzr4jhwrh1x8dvb-bifrost-module-check`.

Bifrost 2.2.6 is retained locally after these gates passed. Consumer adoption,
scheduled refresh/PR creation and automerge remain outside this change.

## Independent review

Verdict: **OK with notes**, no blockers. All four notes were addressed: the
version-specific comment was removed, the installed CLI is smoke-tested,
consumer `NIX_PATH` entries are preserved behind the pinned nixpkgs entry, and
the initial owner registry is asserted to contain Bifrost alone. The focused
runner, consumer, ownership-policy and formatting checks pass after these
changes; both-system evaluation also passes with IFD disabled.
