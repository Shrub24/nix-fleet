# Stock evaluator benchmark — 2026-10-08

## Result

Do not adopt the GC source patch on the strength of the earlier experiment.
Stock `nix-eval-jobs` saves several seconds on the fixture-free checks, but
consumes substantially more memory. It offers almost no elapsed-time advantage
on the package sets. Running native evaluations concurrently is competitive
with stock parallel evaluation. Native Nix completes both fixtures; the stock
evaluator cannot complete the x86 fixture within an 8 GiB budget, even alone.

This measures evaluation, not build throughput. It does not establish that
`nix-fast-build`'s scheduling and result reporting are unnecessary, or that a
native build command is a drop-in replacement for the whole CI workflow.

## Provenance and method

- Source: published commit `6a9148595b560caaa6b43d1f285a189075b4e6f7`, not
  the working copy containing the proposed evaluator patch.
- Source NAR hash: `sha256-04qNH0ao0xsC1+4z0fAjHiD/USrb3WCA2beHEHrWIdQ=`.
- Source fingerprint: `cf7acf7502452b8f7bd91bed884fbc5067fce4c7d236bf939d5f865f5fbb033c`.
- Nixpkgs: `151fa4e8ddfdd8dd25d945ad94ed54a13de9f6e4`.
- Native Nix: 2.35.2. Stock `nix-eval-jobs`: 2.35.4, linked against Nix
  2.35.2 libraries (verified with `ldd`). `nix-fast-build`: 2.0.4.
- Local Linux x86_64 host: 20 logical CPUs, 31.1 GiB kernel-reported RAM,
  31.1 GiB swap. Initial available RAM was 16.1 GiB; initial load average was
  5.51 / 4.24 / 3.46. ARM outputs were evaluated on this host, not timed on
  ARM hardware. These are not GitHub-runner timings.
- `eval-cache = false` throughout. Source, store and filesystem caches were
  already warm; no cache flush or explicit warm-up was performed. Tools were
  prepared outside measured trials.
- Native evaluations force a JSON derivation-path manifest. Stock evaluations
  force the same derivations and also emit their normal metadata/statistics.
  This is an operational comparison, not an identical-output-format benchmark.
- Four small sets: 17 non-fixture checks and 11 non-fixture packages for each
  architecture. Both the fixture check and `packages.<system>.fixture` were
  excluded from those sets. The combined set contains all 56 outputs.
- Isolated/combined stock small-set trials: two workers, 4096 MiB per worker.
  Parallel group: four separate invocations, one worker and 2048 MiB each.
  Fixture stock trials: one worker, 8192 MiB. Each configuration permits at
  most 8 GiB in total. Native Nix had no added memory cap.
- Wall time is monotonic elapsed time; CPU is GNU time's user + system time.
  Aggregate RSS and PSS were sampled every 250 ms across the launched process
  groups, including forked workers. RSS double-counts shared pages; PSS is the
  fair-share measure. Maxima are sampled lower bounds, and PSS uses only fully
  readable samples. Persistent Nix-daemon work is outside these measurements.
- Small isolated sets have two successful trials; values below are mean time
  and maximum sampled memory. Combined/group/complete-fixture results have one
  trial each. There was no randomized order or hardware isolation; small
  differences are not statistically established.

## Small outputs

Memory columns are **aggregate RSS / PSS**, in GiB. CPU time sums user and
system seconds across the launched processes.

| Workload                     | Native wall / CPU (s) | Stock wall / CPU (s) | Native RSS / PSS | Stock RSS / PSS |
| ---------------------------- | --------------------: | -------------------: | ---------------: | --------------: |
| x86 checks, 17               |         12.51 / 13.45 |         8.92 / 13.32 |    1.006 / 0.989 |   2.658 / 2.580 |
| ARM checks, 17               |         13.11 / 15.09 |         7.25 / 11.31 |    1.092 / 1.075 |   2.641 / 2.567 |
| x86 packages, 11             |           2.01 / 1.46 |          1.89 / 2.88 |    0.294 / 0.270 |   0.601 / 0.528 |
| ARM packages, 11             |           1.48 / 1.11 |          1.47 / 2.18 |    0.297 / 0.280 |   0.562 / 0.488 |
| Combined small set, 56       |         23.90 / 29.91 |        14.29 / 22.55 |    1.961 / 1.945 |   4.598 / 4.525 |
| Four small sets concurrently |         12.55 / 32.48 |        15.30 / 29.13 |    2.121 / 1.320 |   3.612 / 1.428 |

All successful cross-method manifests are identical, including the combined
56-output set. Each individual set has six successful matching manifests from
its isolated and grouped trials.

Stock is faster than one serial native process for the checks and combined
set. However, four native processes finish the grouped workload faster in this
run than four single-worker stock invocations. Their physical-memory estimates
are close: 1.32 versus 1.43 GiB PSS. The much larger difference in aggregate RSS
should not be mistaken for the same difference in physical memory consumption.

## Fixtures

| Workload and method                   | Wall (s) | CPU (s) | RSS / PSS (GiB) | Outcome                                   |
| ------------------------------------- | -------: | ------: | --------------: | ----------------------------------------- |
| x86 fixture, native direct attrpath   |   113.07 |  133.93 |   2.808 / 2.790 | Success                                   |
| ARM fixture, native direct attrpath   |   128.03 |  152.43 |   3.054 / 3.038 | Success                                   |
| x86 fixture, stock evaluator alone    |    89.85 |   72.72 |   8.024 / 7.977 | Evaluation failure after two budget kills |
| x86 fixture, real fast-build frontend |   110.33 |   86.24 |   8.050 / 7.998 | Same evaluation failure; frontend exit 1  |

A failed evaluation's time is not a completion speedup. The native fixture
paths are:

- x86: `/nix/store/fdzvllqv1gkdpwi5saxn9kgg0z7gmh2i-nixos-system-nixos-26.11.20261006.151fa4e.drv`
- ARM: `/nix/store/9c8czdy6hzj3dr5bxrhsj616jxfir5rk-nixos-system-nixos-26.11.20261006.151fa4e.drv`

These also match the earlier native probe. There is no successful stock
fixture manifest to compare against them.

The stock x86 result contains:

```text
evaluation exceeded the memory budget of 8192 MiB
(workers * max-memory-size) even when run alone
```

Importantly, `nix-eval-jobs` itself exits **0** while emitting this per-attribute
JSON error. Checking only its process exit code would falsely report success.
`nix-fast-build` correctly reports `EVAL: 0 successes, 1 failures` and exits 1.

`nix-fast-build` 2.0.4 has no supported evaluation-only/dry-run mode. Its real
fixture failure path was measured with guards forbidding builds/copies; neither
build guard was invoked, and its log reports zero builds. This verifies the
frontend failure, not successful build throughput or isolated frontend overhead.
The difference between its elapsed time and the separate direct-evaluator trial
cannot be attributed wholly to frontend overhead.

## Bounds and recording issues

The first suite capped each trial at 90 seconds. Both native fixtures timed
out, as did both stock fixtures. Those four incomplete trials and their raw
samples were retained. Stock ARM exceeded its budget and restarted before the
timeout, but no final ARM stock result was observed; it is not reported as a
completed failure.

The follow-up allowed 180 seconds for fixtures and used direct native CLI
attrpaths rather than the original helper expression. Both native fixtures
then completed, and the stock x86 evaluation reached its own terminal budget
error. These are not byte-for-byte repeats of the native helper-expression
trials. Completed small-set trials were not rerun.

A missing guard variable stopped the supplemental harness after its six valid
measurements, before starting the frontend trial. The frontend was run
separately once. The generic harness initially left frontend error parsing
empty; that reporting field was corrected from the frontend's result file,
with the original record retained. Neither issue invalidated or reran completed
evaluations. CPU totals for the original forcibly terminated trials are
unavailable and were left null, not zero.

## Evidence and reproduction

The full local record is `/tmp/nix-fleet-eval-benchmark/`:

- `metadata.json`, `supplement-metadata.json`, `frontend-metadata.json`;
- `results.json` (28 trials), `manifest-comparisons.json`;
- per-trial `result.json`, raw stdout/stderr, GNU time records and `samples.json`;
- `run.py`, `supplement.py`, `frontend.py` and the generated Nix expressions;
- the frontend's unmodified result file and preserved pre-correction record.

The temporary raw directory also has a verified durable local archive:

- `~/.local/state/nix-fleet/benchmarks/20261008T060419Z-6a9148595b56.tar.gz`
- 149059 bytes; private file permissions (`0600`).
- SHA-256: `6ae89ea8a155e3ad7e34eb21164777e600489f1f17a2311429540dd7da0b2a5c`.

The archive includes all 28 trials, raw logs, sampler data and harnesses. It is
not a public artifact. This document preserves the measured summary and
source/tool provenance. To repeat a fixture evaluation against the same checkout:

```sh
source='git+file:///path/to/nix-fleet?rev=6a9148595b560caaa6b43d1f285a189075b4e6f7'
nix eval --option eval-cache false --json \
  "$source#checks.x86_64-linux.fixture-x86-64-linux.drvPath"
```

The recorded harness supplies the exact worker selections, group workloads and
sampling implementation. No source patch, workload builds, commits or pushes
were performed by the benchmark.
