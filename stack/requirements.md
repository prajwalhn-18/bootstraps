# Stack Bootstrap — PostgreSQL (Pigsty) + Observability (Node.js/TS/OpenTelemetry)

## Intent

A fifth bootstrap alongside `nodejs/`, `go/`, `python/`, `React/` — but instead of scaffolding
an app, it scaffolds the *infrastructure* those apps run against: a Postgres instance and a full
observability pipeline (metrics, traces, logs).

Two commands, two different lifetimes:

1. **Machine bootstrap** — run once per machine/server. Installs and starts Postgres (via
   Pigsty) and the observability stack (OTel Collector + Tempo + Loki, reusing Pigsty's own
   Prometheus + Grafana). Idempotent — safe to re-run on a box that already has it.
2. **Project bootstrap** — run every time you start something new. Creates an isolated DB +
   role for the project on the existing Pigsty instance and prints a ready-to-paste `.env`
   block. Takes seconds.

Any Node/TS app then imports a drop-in instrumentation module, reads that `.env`, and ships
traces/metrics/logs with no further config.

## Why now

Every new side project starts with the same chore: install Postgres, wire up logging/metrics,
remember env var names, hand-roll an OTel setup. This collapses that into "run once per
machine, then seconds per project."

## Goals

- One command installs/starts Postgres (via Pigsty) + Prometheus + Grafana + Tempo + Loki + an
  OTel Collector, on `localhost` or a remote Linux server (same command, just a host flag).
- That command is idempotent: detects an existing install and skips/upgrades rather than
  failing or duplicating services.
- A second, fast command, run per project, creates a Postgres DB + role and prints the env
  block (`DATABASE_URL`, `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_SERVICE_NAME`) — no YAML editing,
  no Ansible knowledge required.
- A drop-in Node.js/TypeScript OpenTelemetry bootstrap file (traces + metrics + logs,
  auto-instrumenting Express/pg/http) that any bootstrapped Node app can import and have it
  "just work" against the env block above.
- Reuses Pigsty's built-in Prometheus + Grafana + Postgres dashboards rather than standing up a
  second monitoring stack — Tempo/Loki/OTel Collector are *additions* wired into that same
  Grafana, not a parallel system.

## Non-goals

- HA / multi-node Postgres. Single-node Pigsty is the target — enough for local dev and small
  servers.
- Go/Python instrumentation in this pass. Node/TS only for now, but the directory layout should
  leave room for `go/` and `python/` instrumentation modules later.
- Production hardening (TLS everywhere, auth rotation, backup/restore drills, alerting). This is
  a dev/small-team convenience tool, not an enterprise rollout playbook.
- Reinventing Pigsty's own Postgres monitoring — don't duplicate what it already gives you.

## Anti-goals (would make this a failure even if "it technically works")

- Re-running the machine bootstrap disrupts an already-running instance or existing databases.
- The per-project script requires hand-editing YAML/Ansible/Docker Compose files.
- Getting a single trace/log/metric out of a Node app end-to-end requires first understanding
  OTel Collector pipeline config.
- The two scripts behave differently enough between local and remote targets that you have to
  relearn the flow for each.

## Constraint to flag explicitly

Pigsty only installs on Linux (EL8/9, Ubuntu, Debian) — it is not a macOS-native tool. "Local"
in this doc means *a Linux host you're developing on or against* (bare-metal Linux box, a VM,
WSL2) — not running Pigsty directly on macOS. If the actual daily driver is a Mac, the "local"
path should target a Linux VM reachable over SSH, exercised through the exact same `--host`
flag as a remote server — i.e. there's really only one code path (SSH to a Linux target),
and "local" is just that path pointed at `127.0.0.1`/a local VM. This is a default assumption,
not something confirmed — flag it back if the real setup is different (e.g. Docker Desktop's
Linux VM, Multipass, Lima).

## Architecture decisions made

- **Postgres + its metrics**: Pigsty, single-node (`meta` single-instance config), installed
  with its bundled Prometheus + Grafana + node_exporter + pg_exporter. Don't touch this part
  beyond initial install — it already does Postgres observability well.
- **Traces + logs + app metrics**: not part of Pigsty, so added alongside it via Docker
  Compose on the same host: an OTel Collector (OTLP receiver), Grafana Tempo (traces), Grafana
  Loki (logs). Metrics from the collector get remote-written into Pigsty's existing Prometheus
  rather than running a second Prometheus.
- **Wiring**: Tempo and Loki are added as data sources to Pigsty's existing Grafana via
  provisioning files — one Grafana, one place to look, for both infra and app signals.
- **Node/TS side**: one instrumentation module (`@opentelemetry/sdk-node` +
  `auto-instrumentations-node`), driven entirely by env vars (`OTEL_EXPORTER_OTLP_ENDPOINT`,
  `OTEL_SERVICE_NAME`), exporting OTLP/HTTP to the collector. No code changes needed per
  project beyond importing it first.
- **Idempotency mechanism**: machine bootstrap checks for markers before acting — an existing
  `~/pigsty` install, the Docker Compose project already up — and skips/no-ops each piece
  already present rather than failing. A `--force` flag can allow explicit reinstall later, but
  default behavior is "make it so, however much of it already exists."

## Directory layout

```
stack/
  requirements.md            <- this document
  bootstrap.sh                <- entrypoint: machine bootstrap (run once per machine/server)
  new-project.sh               <- entrypoint: per-project DB + env block (run every time)
  database/
    install-pigsty.sh          <- idempotent Pigsty install/start wrapper
    create-db.sh                <- creates a DB + role for a project on the running instance
  observability/
    install-stack.sh             <- idempotent docker compose up: otel-collector, tempo, loki
    docker-compose.yml
    otel-collector-config.yaml
    grafana-provisioning/         <- datasource YAML wiring Tempo/Loki into Pigsty's Grafana
    node/
      instrumentation.ts           <- drop-in OTel bootstrap for Node/TS apps
      README.md                     <- one import, one env block, done
```

## Usage (what this should feel like once built)

Once per machine/server:

```
bash stack/bootstrap.sh --host user@my-server      # or: --host local
```

Every time a new project starts:

```
bash stack/new-project.sh my-new-app --host user@my-server
# -> prints:
#    DATABASE_URL=postgres://my-new-app:***@my-server:5432/my-new-app
#    OTEL_SERVICE_NAME=my-new-app
#    OTEL_EXPORTER_OTLP_ENDPOINT=http://my-server:4318
```

Then, in the Node/TS project:

```ts
import "stack/observability/node/instrumentation"; // first import, before anything else
```

## What's left to the builder

- Exact current Pigsty install incantation (installer URL, `configure`/`install.yml` flags) —
  verify against Pigsty's own docs/version at implementation time rather than hardcoding
  commands from memory; wrap whatever it is behind `database/install-pigsty.sh` so this doc
  doesn't need updating if Pigsty's CLI changes.
- Exact idempotency checks (what marks "already installed" for Pigsty vs. for the Docker
  Compose observability stack).
- Whether `new-project.sh` also scaffolds the `.env` file directly into a target project
  directory or only prints the block for manual paste.
- Whether to fold this into the existing root `bootstrap.sh` as a 5th `project_type` later, or
  keep it a standalone two-script tool under `stack/` indefinitely.
- Grafana provisioning file format/paths depend on the Grafana version Pigsty ships — confirm
  at build time.
