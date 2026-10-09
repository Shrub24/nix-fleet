# Design

## Context

See proposal.md for scope. The current contract has dormant scrape registrations but no shared identity. vmagent and the Collector independently render `source.labels`; producer and health jobs derive `instance` from `networking.hostName`. Collector `resourceAttributes` defaults to empty and renders an upsert processor for local pipelines, excluding it from general and route ingress. Vector sends journal records straight to its disk-buffered HTTP sink.

The existing node-exporter aspect owns a loopback exporter and registration. The Tailscale aspect owns the daemon but no metrics registration. NixOS supplies SMART and process exporter modules. Podman PR #507097 adds an exporter-helper module and package, not a standalone importable NixOS module; its package builds with the `remote` tag and its service uses `CONTAINER_HOST`.

## Goals / Non-Goals

Give host-local signals a common origin without rewriting forwarded resources. Keep application identity separate from host, unit and scrape endpoint identity. Make correlation extraction conservative and lossless for the original log record. Reuse native NixOS exporter options rather than duplicate their full option trees.

No new dependency-management options, implicit lane activation, per-host service identity, arbitrary remapping language or broad upstream runtime suite. Deferred mechanisms are listed in proposal.md.

## Decisions

### 1. Identity is shared data, not an aspect

Declare `services.telemetry.identity.hostName` as a nonempty string, defaulting to `networking.hostName` in a NixOS contract evaluation. Declare `environment` as null or a nonempty string, default null. The vocabulary remains inert; producer selection never starts a scraper.

Project host into `host.name`, metric label `host`, and log field `host_name`; project a bound environment into `deployment.environment.name`, metric label `environment`, and log field `environment`. Preserve `instance`, `job`, `service.name`, journal `_HOSTNAME` and `_SYSTEMD_UNIT` independently. Do not change existing instance values just to make them resemble host identity.

Alternative: repurpose `instance` or `_SYSTEMD_UNIT` as universal identity. Rejected because scrape targets and application/unit boundaries do not identify the same thing. A global service name is likewise incorrect on a multi-service host.

### 2. Projection follows the origin boundary

Canonical host/environment enrichment applies to host-local OTLP inputs and journal records. General network ingress and named routes retain originating resources, including missing host attributes; gateway identity is not a substitute. Existing native output-view overrides must preserve this exclusion.

Merge identity with Collector resource enrichment. Contradictory configured `resourceAttributes` for the canonical keys fail with named errors; matching values are harmless. Other resource attributes remain supported. Producer `service.name` is not generated or overwritten.

For scrape registrations, add canonical host/environment labels as defaults before the explicit source labels. Explicit source-level `host`/`environment` labels may describe a remote target; they are an intentional origin override, not a new global identity. Existing exporter sample-label precedence remains unchanged. Locally owned producer jobs use the canonical values. No global remote-write label stamps telemetry merely passing through a collector.

Alternative: enrich every gateway pipeline or all remote-write samples. Rejected because that labels the transit machine as the origin. Remote probe identity/vantage modeling is deferred rather than inferred from target address.

### 3. Normalize trace context without expanding the log payload

Add `services.telemetry.journald.normalizeTraceContext`, default true. The Vector realization inserts a remap transform before the sink and therefore before its disk buffer. Supported carriers in this first version are exact `trace_id` / `span_id` keys in the source record or at the root of a JSON object in `message`. Broader aliases and nested layouts require explicit future support, not heuristic discovery.

An existing source-record key takes precedence over message JSON. If that key is invalid, do not silently replace it from a lower-precedence carrier. Valid normalized fields are lowercase, nonzero, hexadecimal: 32 characters for trace ID and 16 for span ID. A span ID is promoted only alongside a valid trace ID; a trace ID without a span ID is useful and retained. Invalid promoted correlation keys are omitted, but the original `message` and journal metadata remain unchanged. The transform never aborts or drops a record on parse failure.

Only the allowlisted IDs are copied from parsed JSON. The message cannot overwrite host/environment, timestamps, unit fields or service metadata. Existing valid top-level IDs are normalized even for plain-text messages. Disabling normalization preserves existing pass-through behavior apart from independent identity enrichment.

Alternative: merge parsed JSON wholesale or regex-search arbitrary text. Rejected because payload fields can shadow trusted metadata and ordinary strings can be mistaken for context. IDs stay out of stream fields and metric labels. This is correlation plumbing, not proof that a referenced trace exists or an authenticated identity.

### 4. Producers follow the existing registration model

- Existing `node-exporter`: append the `systemd` collector; consumer native options retain unit filters and optional detailed counters. No separate systemd exporter.
- Existing `tailscale`: register the local daemon endpoint at `100.100.100.100:80/metrics`. Do not enable `--webclient`, OAuth credentials or a tailnet-facing metrics listener. Selecting Tailscale already declares its daemon dependency.
- New `smartctl-exporter`: compose the native SMART module, loopback listener, scrape registration and notify registration. Keep device/exclusion/polling policy in native consumer options and document capabilities/raw-device access; never auto-select it on every host.
- New `podman-exporter`: compose the adapted implementation and local socket dependency, exporter, loopback registration and notify. First version targets rootful local Podman only and declares Podman as a dependency by imports. Do not grant arbitrary remote-engine endpoints or rootless user-service inference.
- New `process-exporter`: compose the native module and loopback registration. Require a nonempty consumer-supplied `settings.process_names` with a named error rather than inventing a catch-all. Recommend stable names and disabled per-thread collection unless requested; native options remain the configuration surface.

Alternative: a host-wide producer catalog that infers enablement from configured entries. Rejected in favor of aspect selection. Package collectors publish facts; consumers select the metrics transport and notify capability independently.

### 5. Vendor the Podman PR narrowly

Use the complete verified head revision from PR #507097 (the reviewed head begins `b859cd0bd7be`; record the full SHA and hashes during implementation). Preserve its source/license attribution and version 1.21.2 as the starting package. The reviewed derivation's remote build mode explains its socket requirement; do not claim it is a read-only native libpod client.

Place the package under `pkgs/` and any adapted non-flake-parts implementation under `lib/`. Do not place raw nixpkgs exporter-helper content under auto-discovered `modules/`. Integrate its exporter-helper contract rather than assuming it can be imported alone. Ensure socket activation, effective service UID/access and loopback binding work with the pinned exporter framework; do not rely on group membership as proof of functioning access.

Keep a stable fleet aspect while replacing this temporary package/module once the fleet's nixpkgs pin contains the merged implementation. If upstream changes names or options, adapt internally rather than force hosts to select another mechanism. No blind overlay of the entire PR or extra floating nixpkgs input.

### 6. Validate authored boundaries

Use bare contract evaluations for identity values and named failures; focused NixOS evaluations for rendered native identity, origin exclusion, producer listener/registration agreement and dependencies. Exercise the Vector remap with representative records using the pinned runtime: valid IDs, malformed JSON, wrong-length/zero IDs, precedence, trace-only records and metadata-shadowing payloads. Include a mutation that removes the transform or corrupts validation and is caught.

Build the vendored Podman package and run one focused rootful-container smoke check covering our packaging/socket/service integration. Do not retest every upstream metric. Each leaf states one claim and remains within the evaluator budget. Consumer live checks remain explicitly separate.

## Risks / Trade-offs

- Additional labels change metric series identities → document the transition; do not rewrite historical data or queue identities.
- Loopback is origin scope, not authentication → retain the existing trust boundary and exclude network ingress from enrichment.
- JSON parsing adds per-record work → parse only the message object for the small allowlist, preserve original payload and avoid duplicated parsed fields.
- SMART requires powerful device access; Podman socket permits engine control → expose these privileges in docs and keep selection explicit.
- Process names/arguments and container labels can leak content or churn series → no blanket selection, no full-command-line group names, no unrestricted container-label copying.
- Tailscale endpoint behavior and PR service access remain source-backed, not locally observed → verify those specific boundaries during implementation; report a blocker instead of enabling broader exposure.

## Migration Plan

Land contract/projections and normalization first, then producers. Consumers bind environment and any host override from existing fleet facts, select optional aspects and supply disk/process policy. Verify one host's host identity across signals and a known trace ID in logs; separately configure backend links. Publish only after focused checks and full gates pass.

Rollback deselects optional producer aspects and can disable normalization. Reverting the revision removes generated identity fields/labels; old series and old logs remain. Remove vendored Podman code only after the pinned upstream replacement passes the same integration boundary.
