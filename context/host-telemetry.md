# Host telemetry

## Canonical identity describes origin, not the collection endpoint

**Id:** 07b04986-490c-4ad2-8918-3e7428f12c93
**Type:** decision
**Status:** active
**Evidence:** confirmed

Host and optional environment identity are shared contract values. Local OTLP resources, scrape defaults and journal fields project those values into their native representations. Forwarded OTLP keeps the sender's resource identity; explicit scrape-source labels override collector-local defaults. Application `service.name`, systemd unit names and existing Prometheus `instance` values remain independent.

**Reason:** an application, its owning unit and its scrape endpoint are different objects. A collector may also scrape another machine, so stamping its resource identity onto every pipeline would contradict the source's origin labels. The host name defaults from NixOS rather than creating another machine inventory; a consumer override derives from canonical fleet data.

**Rejected alternative:** reuse `instance` or the systemd unit as universal identity. Neither consistently identifies the originating machine or application.

**Rejected alternative:** apply gateway identity to every signal that passes through it. That attributes remote telemetry to the collector and fills missing sender identity with a false origin.

## Journal normalization promotes context without trusting the whole message

**Id:** a3b229cd-831f-4c16-b1ea-22e0cb5808a9
**Type:** decision
**Status:** active
**Evidence:** confirmed

Only supported trace/span keys are promoted from structured messages. Source-record keys take precedence even when invalid; invalid preferred context does not fall back to a different value in the message. The original message and journal metadata survive parsing failure. Correlation fields are searchable data, not log stream keys or metric labels.

**Reason:** arbitrary JSON merging lets an application message shadow journal host or unit metadata. Falling back after a malformed preferred key can attach a log to a different request rather than expose the malformed context. IDs identify individual operations and therefore have unsuitable cardinality for storage partitioning or metric labels.

**Rejected alternative:** merge parsed JSON into the record or guess context from arbitrary text. Both expand the trust boundary beyond explicit correlation carriers.

## Podman's temporary exporter adaptation uses the rootful socket deliberately

**Id:** edd366aa-2c6e-41fb-9ac9-77932c8e22b6
**Type:** workaround
**Status:** active
**Evidence:** confirmed

The package and module adaptation are pinned to nixpkgs PR #507097 at `b859cd0bd7be2b0ea7d5810dab7c537e9c650a59`. Its remote build uses the rootful local Podman socket. Selecting the producer composes the existing Podman aspect and grants the exporter engine-socket access; that access permits engine control, not just metric reads.

**Reason:** the current nixpkgs pin lacks the package/module. The adaptation keeps packaging and socket wiring reproducible without modifying the input. Replace it when the fleet pin includes the upstream implementation and the owned socket/registration integration still passes, not merely when the PR merges.

**Rejected alternative:** use the native libpod build interchangeably with the PR's remote build. They have different engine-access mechanisms; the socket-client adaptation must be verified with the package it actually runs.

**Revisit when:** the fleet's nixpkgs pin contains the merged Podman exporter package and module.
