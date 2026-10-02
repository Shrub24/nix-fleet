# Tasks

## 1. Dendritic telemetry composition

- [x] 1.1 Convert telemetry providers into sibling flake-parts contributors merging the single `flake.modules.nixos.telemetry` aspect; verify the fixture can select that aspect and no additional provider aspect is exported.
- [x] 1.2 Move the reusable options/orphan fragment to `lib/telemetry-contract.nix`, update node-exporter and fixture imports, and delete obsolete telemetry implementation paths without shims; verify named orphan checks still pass and no old telemetry-fragment imports remain.
- [x] 1.3 Update README layout and the producer-fragment/composition examples in `docs/contracts/telemetry.md`; verify paths match the new tree and the node-exporter example evaluates.

## 2. Explicit admission and capability-driven activation

- [x] 2.1 Add typed `otlp.signals` with an empty default, reject duplicates and admitted signals with no valid destination pipeline, and require active OTLP work for URL reads; verify named mutation checks for each failure and a valid trace-only URL read.
- [x] 2.2 Derive OTel work, active signal pipelines and the union of actually used exporters from OTLP admission plus selected OTel scrape work; verify vmagent-only and Vector-only fixtures create no OTel service/listeners while the explicit OTel scrape override works with OTLP disabled.
- [x] 2.3 Bind credentials and validation overrides only for active provider destinations, moving shared secret-ID/pairing validation into the contract; verify inactive backend credentials create no OTel secret or exporter and existing vmagent charset/parser-safety checks remain green.
- [x] 2.4 Update the fixture's existing vmagent expectation that currently requires an OTel metrics pipeline, add combined-capability activation checks, and document the explicit-admission migration; verify trace-only hosts do not start vmagent/Vector and metrics-only hosts do not start OTel.

## 3. Local receiver and explicit gateway ingress

- [x] 3.1 Constrain the producer listener to loopback and add nullable additional ingress with an explicit host and selected HTTP/gRPC transports; verify named failures for non-loopback local binding, wildcard/empty ingress, no transport and identical listener bindings.
- [x] 3.2 Render distinct local and ingress receivers feeding shared selected exporter IDs without a role switch; verify generated local URLs stay loopback, both listeners operate in the real collector, and absent ingress produces no network listener/firewall opening.
- [x] 3.3 Build source-specific pipelines so local resource enrichment does not apply to forwarded telemetry; verify synthetic remote traces retain their original host/service identity alongside gateway-local traces.
- [x] 3.4 Verify admitted-signal handling using real OTLP HTTP requests: traces succeed while metrics/logs sent to a trace-only receiver receive rejection; cover both local and additional ingress and document any protocol-specific response semantics.
- [x] 3.5 Document relay/gateway compositions and explicit resolver binding in the contract guide; verify example fixture configurations validate and gateway selection adds neither remote scraping nor journald shipping.

## 4. Persistent OTel delivery

- [x] 4.1 Add supported `file_storage` configuration in the existing service StateDirectory with restrictive access and fsync, persistent exporter queues with 256 MiB serialized-payload capacity, bounded attempts, retryable failures without the upstream five-minute expiry and explicit overflow rejection; verify the generated config with the pinned Collector Contrib 0.155.0 binary.
- [x] 4.2 Replace default volatile pre-export batching with queue-integrated batching and retain explicit upstream/provider tuning; verify the default rendered pipelines contain no standalone batch processor and the collector validates the integrated queue configuration.
- [x] 4.3 Add a bounded offline integration harness with synthetic OTLP IDs and local controllable receivers; verify successful acceptance followed by abrupt collector termination, restart with unchanged state and downstream recovery delivers every accepted ID, permitting duplicates.
- [x] 4.4 Extend that check to three exporter queues with one unavailable backend, then restore it; verify healthy branches continue and the failed branch recovers its accepted backlog without another producer send.
- [x] 4.5 Exercise a deliberately small queue and exhausted storage path; verify enqueue failure is returned within a bounded test deadline and no success is mistaken for durable acceptance.
- [x] 4.6 Document queue units, supported compaction, physical database overhead, retry/overflow behaviour, sensitive on-disk payloads, custom asynchronous-processor caveats and stable exporter IDs; verify documentation does not claim a physical database cap unsupported by 0.155.0 or exactly-once delivery.

## 5. Delivery-health visibility and coordinated adoption

- [x] 5.1 Configure active OTel operational metrics on loopback port 9464 with an upstream override and register its owned unit failure only while active; verify queue/capacity/failure metrics in the real-binary check, no implicit port 8888 listener, no public management opening and no OTel notification event on metrics-only hosts.
- [x] 5.2 Document a scrape registration for collector health through the existing producer interface; verify the example against a fixture with a compatible metrics destination and that hosting operational metrics alone does not start another provider.
- [x] 5.3 Add an adoption/rollback guide for home-forge deployment, explicit admission, local versus container/standalone bindings, credential scope, allowed/denied tailnet tests, origin preservation and queue-state retention; verify it distinguishes offline mechanism checks from consumer-owned live acceptance.
- [x] 5.4 Document the gated catalog transition for the existing `otel-collector.otlp` endpoint: deploy and verify home-forge first, then publish coordinates, relock agents and remove direct agent trace-backend legs; verify no canonical coordinate is changed or consumer service moved solely on the basis of the plan.

## 6. Integrated acceptance

- [x] 6.1 Snapshot new/deleted implementation files with jj before Nix validation, run `nix fmt`, `nix flake check --all-systems` and the native fixture plus new runtime delivery check; verify formatting, all-system evaluation and native builds are green without real credentials, tailnet access or live backends.
- [x] 6.2 Review the complete capability matrix and named mutation evidence against all three delta specs; verify each scenario has an evaluation/runtime check or an explicitly identified consumer deployment gate and report any remaining limitations without claiming live adoption.
