# Substituter order

## The substituter catalog is ordered by measured substitution cost, not by ownership

**Id:** 5e558c8e-ee1d-4771-8ed8-b768fab6c927
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** substitution matrix over a 296 MB closure and a 3.57 GB fresh-store
closure, and the `Priority` each cache declares in `nix-cache-info`, 2026-10-27
**Revisit when:** the fleet cache's negative path stops costing about 450 ms and
28 KB per miss, or a cache's coverage or per-connection throughput changes enough
to reorder the middle of the list

`substituters` carries explicit priorities: `cache.nixos.org` on the 40 nixpkgs
already seeds, `cache.numtide.com` 41, `nix-community.cachix.org` 42, and the
fleet's own cache 45. The fleet cache is ordered as a supplement — the source for
what no public cache carries (unfree, insecure, patched and the fleet's own
builds) — rather than as the preferred source.

**Reason:** the fleet cache is 24% faster than `cache.nixos.org` on a closure both
hold (4.0 s against 5.3 s for 63 paths; its edge sits 15–21 ms away against
48–115 ms), but 12% slower the moment it misses (43.8 s against 39.1 s), because
every miss costs about 450 ms and a 28 KB error page that the edge does not
cache. A rebuild after a nixpkgs move misses hundreds of upstream paths, which at
eight substitution jobs is tens of seconds; the handful of paths only the fleet
cache holds cost a few misses at the back of the queue instead. Numtide precedes
nix-community on coverage (it served 214 of a 218-path fresh closure, against
nix-community serving 23% of a running system) and on throughput (32.6 MB/s
single-stream against 24.0), which outweighs nix-community's cheaper round trip.

**Rejected alternative:** rank the fleet cache first. It wins on sets that miss
nothing and on a second machine that never built the paths, but the machine doing
the rebuild pays a miss per changed path to buy an advantage it can only realise
when nothing misses. It becomes the better order once the cache's negative path
is cheap and edge-cached.

**Rejected alternative:** declare the priority in the cache's own
`nix-cache-info`. That value is global to the cache: it would order the fleet
cache first for nodes in other regions, where no edge copy is warm, to favour the
machines nearest the bucket. Ordering is a property of the client, so it is
configured here.

**Follow-up:** the ordering rests on a 404 costing 450 ms and 28 KB. If the
Cloudflare route in front of the bucket is changed to answer a missing object
with an empty, briefly cached 404, the fleet cache's first-place advantage
(24% on hot closures) returns without the miss tax and this ordering should be
re-measured rather than assumed.
