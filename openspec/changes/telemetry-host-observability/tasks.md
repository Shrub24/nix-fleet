# Tasks

## 1. Shared identity and native projections

- [x] 1.1 Declare typed host/environment identity with defaults and named invalid-value errors; verify bare contract cases for defaults, explicit override, empty values and inert declarations.
- [x] 1.2 Project identity into local Collector resources and both scrape renderers, retaining explicit source labels and rejecting conflicting canonical resource configuration; verify rendered native fields, unchanged job/instance/service identity, source overrides and no enrichment on general or named-route ingress.
- [x] 1.3 Project identity into Vector journal records without rewriting trusted metadata; verify rendered transform placement and representative conflicting payload fields, and document field mapping, precedence and metric-series migration in the telemetry contract.

## 2. Journal trace-context normalization

- [x] 2.1 Add the default-on normalization option and implement the exact carrier/validation rules from design.md before the disk-buffered sink; verify with the pinned Vector runtime that valid IDs normalize, trace-only context survives, invalid IDs and malformed JSON do not drop logs, source precedence holds, and original message/unit/host fields remain intact.
- [x] 2.2 Add a focused feature-owned normalization check with a non-vacuity mutation and opt-out coverage; verify removing or corrupting the authored transform is caught and trace/span IDs are absent from generated stream keys and metric labels.
- [x] 2.3 Document supported root-level carriers, limitations, trust boundaries and backend linking handoff; verify examples match the checked record fixtures rather than promising arbitrary text extraction or retained traces.

## 3. Existing producer coverage

- [x] 3.1 Append the node-exporter systemd collector without a second service, preserving native filters/flags; verify its effective arguments and listener/registration agreement and document available versus optional counters.
- [x] 3.2 Register Tailscale's local daemon metrics and contract vocabulary in its existing aspect; verify the rendered target and absence of new webclient/firewall/OAuth configuration, obtain a targeted endpoint smoke result or report the exact environmental limitation, and document that source evidence separately from deployment evidence.

## 4. Optional SMART and process producers

- [x] 4.1 Add the SMART aspect using native module options, loopback binding, matched registration and notify intent; verify effective service privileges, port override and dormant registration, and document consumer device/polling policy and raw-device access.
- [x] 4.2 Add the process-exporter aspect with consumer selectors and a named empty-selector failure; verify effective configuration, loopback/registration agreement and the rejection case, and document stable naming, child/thread attribution and process-access limitations.

## 5. Temporary Podman adaptation

- [x] 5.1 Resolve and record the full reviewed PR #507097 revision, vendor/adapt its package and exporter-helper module outside auto-discovered feature modules, retaining provenance and remote build mode; verify the package builds on x86_64 and evaluates on aarch64 against the fleet pin, and document the pinned-upstream replacement condition.
- [x] 5.2 Add the Podman exporter aspect declaring its rootful local engine/socket dependency, effective access and loopback registration without unrestricted container labels; verify effective configuration and a focused container smoke check covering package/service/socket integration, and document socket authority and deferred rootless support.

## 6. Integrated acceptance and handoff

- [x] 6.1 Run targeted feature checks, formatting, `nix flake check`, `nix flake check --no-build --all-systems` and strict OpenSpec validation; verify all pass without duplicate evaluation claims or exceeding the established per-leaf budget.
- [x] 6.2 Record confirmed rationale through the project's context workflow and sync accepted specs; verify `ktw-lint --strict` and strict spec validation pass, without changing unrelated output-view helpers or consumer policy.
- [ ] 6.3 Deliver the verified revision/API and migration checklist to consumers; verify the handoff distinguishes checked rendering/runtime results from remaining live cross-signal identity, trace lookup, device visibility and backend-link configuration.

## Workflow follow-up

- Archive after implementation verification and review.
- Replace the temporary Podman adaptation after the fleet pin contains a verified merged implementation, preserving the public aspect and registration.
- Track consumer deployment separately; publication does not prove backend correlation links or exporter access on every machine.
