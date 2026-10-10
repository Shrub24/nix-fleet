# Host-local exporter producers

These producer aspects publish local scrape registrations. They name no metrics
store and do not select a scraper: a registration remains dormant unless the
host also composes a metrics realization (normally `telemetry-metrics`). They do
not enable firewall ports. Producers are independently selected — collecting a
new signal is an explicit host choice, not a baseline side effect.

## Systemd units: node-exporter

The existing `node-exporter` aspect enables the node-exporter's `systemd`
collector. It reports unit state through the existing node-exporter process
and scrape job; there is no second systemd-exporter service. Unit state is what
the collector emits by default, and reading it needs DBus over a unix socket,
so the effective collector list also keeps `AF_UNIX` in the service's
`RestrictAddressFamilies`.

The contribution is one ordinary entry in nixpkgs' `enabledCollectors` list, so
consumer additions concatenate rather than replace: a host setting
`enabledCollectors = [ "textfile" ]` renders `[ "textfile" "systemd" ]`. A
consumer that deliberately wants the fleet collector gone uses `lib.mkForce`.

Restart, task and start-time counters are opt-in and require native exporter
flags, for example:

```nix
services.prometheus.exporters.node.extraFlags = [
  "--collector.systemd.enable-restarts-metrics" # service_restart_total
  "--collector.systemd.enable-task-metrics" # unit_tasks_current / unit_tasks_max
  "--collector.systemd.enable-start-time-metrics" # unit_start_time_seconds
];
```

Keep `--collector.systemd.unit-include` / `--collector.systemd.unit-exclude`
policy in nixpkgs' `services.prometheus.exporters.node.extraFlags` (or its
native options if the pinned module exposes them): systemd unit names and
counter cardinality are consumer policy. The scrape `instance` remains the
existing `host:port` value.

## Tailscale client metrics

Selecting `tailscale` registers the daemon's local
`http://100.100.100.100/metrics` endpoint. It starts neither a separate exporter
nor a scraper; a composed metrics realization consumes the registration.

In pinned Tailscale 1.102.5, `/metrics` uses the daemon's own LocalAPI proxy
before browser-session authorization. It does not inspect the scraper's UID:
vmagent's DynamicUser needs no operator grant, supplementary group or Unix-socket
access. The operator rule governs the separate LocalAPI socket path.
`tailscale set --webclient` enables remote access and is not needed here. See the
[pinned HTTP handler](https://github.com/tailscale/tailscale/blob/v1.102.5/client/web/web.go#L360-L364).

Availability still depends on daemon state and consumer network policy. During
startup or with the tailnet `disable-web-client` capability, the endpoint can
return HTTP 200 with fallback HTML rather than metrics. On deployment, check
scrape health and an expected series such as `tailscaled_health_messages`, not
HTTP status alone. The UID conclusion is source-verified; a live DynamicUser
smoke test was not performed.

## SMART disk metrics

Compose `smartctl-exporter` only on hosts whose disks should be monitored. It
uses nixpkgs' native `services.prometheus.exporters.smartctl` module on
`127.0.0.1`, registers the same port, and registers the unit's failure for the
optional notification aspect. Consumers configure `devices` (empty means
nixpkgs auto-discovers devices) and `maxInterval` through that native module.

**Privilege:** nixpkgs gives smartctl-exporter `CAP_SYS_RAWIO` and
`CAP_SYS_ADMIN`, membership in `disk` and `smartctl-exporter-access`, NVMe udev
ACLs, and access to block devices. This is a sensitive host capability, not a
read-only scrape privilege. Select the aspect only where disk health data is
wanted; explicitly list devices and choose a poll interval that matches the
fleet's device count and IO budget.

## Process metrics

Compose `process-exporter` only on hosts with deliberate process selectors. The
aspect uses nixpkgs' native `services.prometheus.exporters.process` settings on
`127.0.0.1` and refuses an empty `settings.process_names` list by name: no
catch-all means a typo cannot silently monitor every process. A consumer example
is:

```nix
services.prometheus.exporters.process.settings.process_names = [
  { name = "web"; comm = [ "nginx" ]; }
  { name = "database"; exe = [ "postgres" ]; }
];
```

Prefer stable, low-cardinality group names matched on `comm`/`exe`; do not use
full command lines as metric labels. Keep `threads` disabled unless there is a
specific need: per-thread labels can multiply series. Process visibility is
constrained by OS permissions and nixpkgs' systemd hardening; do not infer that
an exporter can see processes hidden from its service.

## Podman container metrics

Compose `podman-exporter` only on a rootful Podman host. This aspect imports the
existing `podman` aspect, the vendored package and the narrow adaptation of
nixpkgs PR #507097. The package is `prometheus-podman-exporter` 1.21.2 from
upstream source tag `v1.21.2` (source hash
`sha256-7AU/LWRClwuPEEalhanglMlpXirzFELhdX+6lbu/6zA=`), vendored from PR head
`b859cd0bd7be2b0ea7d5810dab7c537e9c650a59`. The remote Go build tag uses the Podman
REST API, and the service points at the host's rootful system socket:
`unix:///run/podman/podman.sock`. The socket is controlled by nixpkgs' existing
`podman.socket`, whose group is `podman`; the exporter runs with a DynamicUser
in that supplementary group and waits for the socket unit. The socket permits
engine control, not read-only metrics access. This aspect does not infer
rootless user services or allow arbitrary remote engine URLs.

The listener binds loopback, the scrape registration tracks its port, and no
arbitrary container labels are copied by default. The temporary adaptation
exposes `services.podmanExporter.extraFlags` as a narrow escape hatch; if
`--collector.store_labels` is enabled, explicitly whitelist bounded,
non-content-bearing labels via `--collector.whitelisted_labels`. Labels can
contain secrets or other content and can create high-cardinality series.

The vendored package should be removed only when the fleet's nixpkgs pin
contains the merged package and exporter module **and** the same rootful
socket-access and registration checks pass; keep the fleet-facing
`podman-exporter` aspect and `podman` scrape job name stable through that
replacement. PR merge by itself does not satisfy the pin condition.

### Evidence and limits

- **Source evidence:** PR #507097 head and package/module content were fetched
  from GitHub. The package's remote-mode build tag is upstream's explicit
  socket-client contract; the pinned nixpkgs podman module declares the system
  socket and `podman` group.
- **Live Tailscale endpoint:** on this development host,
  `curl http://100.100.100.100/metrics` returned HTTP 200 with Prometheus-formatted
  `tailscaled_*` series. This is a live observation of
  this host's existing daemon only; it does not assert every consumer host's
  daemon exposes the endpoint.
- **Podman guest smoke:** `checks.podman-exporter-vm` is the focused disposable
  NixOS VM check. It uses the pinned OCI module's `imageFile` loader with a
  locally built image archive and exercises the rootful Podman socket, exporter
  service and container metrics inside the guest. It is registered on
  `x86_64-linux` only: what it proves does not vary with the architecture, and no
  aarch64 builder in the fleet advertises `kvm` — the aarch64 builders offer
  `big-parallel`, the x86_64 ones `kvm` and `nixos-test` — so a per-system copy
  could never be built or cached and would fail the fleet build on every
  dispatch. The check passed; this proves the packaged service/socket
  integration, not device or container
  visibility on every consumer host. The real
  development-host rootful socket is `root:podman` mode 0660, the current
  unprivileged user is not in `podman`, and privileged commands are prohibited.
  We do not perform a real-host privileged smoke test.
