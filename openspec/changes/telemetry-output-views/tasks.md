# Tasks

## 1. Native output composition

- [x] 1.1 Add a minimal checked Nix example composing the existing OTLP realization, an explicit route and native lean/rich sibling pipelines; verify the evaluated receiver assignments, disjoint exporter assignments, unchanged exporter identities/credentials, preserved general pipeline and Latitude destination settings (`X-Latitude-Project` with synthetic project data and `compression = "none"`).
- [x] 1.2 Register a bounded output-view evaluation leaf and include its name in the check registry guard; verify a mutation that duplicates a destination assignment is rejected by the composition check. Both leaves are feature-owned (`modules/telemetry/output-view-checks.nix`) and land automatically through `import-tree`; the contract registry holds `{ message; ok; }` evaluation booleans, so a runtime derivation and a duplicate `checks.<system>` attribute are both wrong there.
- [x] 1.3 Document the native override recipe in the telemetry contract, including declared versus effective routing, branch-only processor placement and shared-listener scope; verify the example is imported by the evaluation check rather than being a separately maintained snippet.

## 2. Payload profiles and backend compatibility

- [x] 2.1 Add representative synthetic Hindsight lifecycle, LLM, tool and exception payloads to the output-view harness and implement the example's lean metadata/content profile; verify every forbidden carrier sentinel disappears while received span IDs, parents, timing/status and useful metadata survive.
- [x] 2.2 Add a Latitude-only inference-event adapter with existing canonical attributes taking precedence; verify emitted message attributes through an offline probe using the actual pinned Latitude 0.3.118 parser, record the exact command/source revision, and do not claim live ingestion. The parser accepts the deprecated `gen_ai.prompt`/`gen_ai.completion` carriers for Hindsight's `{role, content}` arrays (`parseGenAIDeprecated`); the current-carrier parser needs parts-based messages and does not surface plain-text system instructions on 0.3.118.
- [x] 2.3 Document the checked retained/removed fields, rich-view content duplication, unprotected resource/status/upstream-storage surfaces and consumer-reported Latitude 0.3.118 project-header/uncompressed-protobuf requirements; verify documentation matches the representative fixtures, adapter precedence test and rendered exporter settings.

## 3. Runtime isolation and delivery

- [x] 3.1 Register a runtime output-view check using the pinned Collector and mock OTLP backends; verify rich/lean mutation isolation, ordinary-only traces and a late continuation arriving in a separate export request, without tail selection or added volatile batch acknowledgement.
- [x] 3.2 Extend that check with adjacent general-route traffic and one unavailable rich destination; verify general traces never reach specialized outputs, the lean branch continues while queue capacity is available, and recovery preserves the rich payload and route assignment.
- [x] 3.3 Add deployment and rollback guidance, including effective-pipeline assertions and sparse-LLM alternatives; verify it retains existing exporter storage identities and does not imply authentication, complete upstream instrumentation or automatic post-ingestion cleanup.

## 4. Integration and handoff

- [x] 4.1 Run formatting, strict OpenSpec validation, focused evaluation/runtime checks, `nix flake check` and `nix flake check --no-build --all-systems`; verify all required gates pass and existing routing/delivery checks remain green. Both gates passed on the rebased tree; `checks.aarch64-linux` also evaluates the two new leaves.
- [x] 4.2 Record the native-seam decision in the project's context, sync the approved spec deltas and run `ktw-lint --strict`; verify no processing DSL or default production-policy change entered the diff. Three entries in `context/telemetry-composition.md`, `ktw-lint --strict` clean, and `openspec validate --all --strict` passes with the new `telemetry-output-views` capability and the merged `telemetry-stream-routing` requirement.
- [ ] 4.3 Deliver the checked example and exact verification results to the homelab owner, including the remaining live-ingestion checks; verify the owner acknowledges receipt and keeps gateway composition/producer binding consumer-owned.

## Workflow follow-up

- Homelab applies its own lean/rich profiles and Hindsight endpoint binding, then verifies live backend delivery and parsed message display. This is not a nix-fleet implementation task.
- Measure ordinary-only trace count/bytes and UI cost before deciding on a separate sparse-LLM policy or bounded selector.
- Archive after implementation and review; the pending AI endpoint publication remains a separate slice.
