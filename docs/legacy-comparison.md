# Legacy comparison: `moodle-nginx` vs. `psa-moodle`

A feature-by-feature comparison of the legacy `bcgov/moodle-nginx` deployment against the new `psa-moodle` re-platform, identifying gaps to close and patterns to leave behind.

---

## Features both systems cover (differently)

| Capability | Legacy (`moodle-nginx`) | New (`psa-moodle`) | Notes |
|---|---|---|---|
| Container builds | 6 separate workflow files (php.yml, web.yml, cron.yml, db.yml, moodle.yml) | Single `build.yml` with Makefile targets | psa-moodle is simpler — one workflow, Podman-native |
| Deploy to OpenShift | `oc process` against template.json + DeploymentConfigs | `helm upgrade --install` with proper Deployments | Helm is more maintainable; DCs are deprecated upstream |
| DB backups | bcgov/backup-storage Helm chart (daily at 1 AM, verbose at 4 AM) | Crunchy pgBackRest (hourly incremental + daily full) + integrity verification + weekly restore rehearsal | psa-moodle is significantly stronger here |
| Maintenance mode | Manual enable/disable during deploys via CLI | Same (`upgrade.php --non-interactive` is idempotent) | psa-moodle doesn't need explicit maintenance mode because immutable images mean the cutover is atomic |
| Cache (Redis/Valkey) | Bitnami Redis Cluster (Helm), commented out in config | Valkey 7.2 with sessions + MUC wired in from day 1 | Legacy never actually enabled Redis sessions in prod config |
| DB replication | MariaDB 3-replica StatefulSet (primary + 2 replicas, manual replication setup) | Crunchy Postgres (operator-managed HA, automatic failover) | psa-moodle eliminated split-brain risk |
| Health checks | `healthcheck.sh --innodb_initialized --connect` (MariaDB), `php-fpm-healthcheck` (PHP) | `pg_isready`, `valkey-cli ping`, `php-fpm-healthcheck`, nginx `/health` endpoint | Equivalent coverage |
| Cron | Long-running Job with infinite loop | Kubernetes CronJob (isolated pod per tick) | psa-moodle avoids memory leaks and zombie processes |
| Plugin management | Purge missing plugins during deploy | Baked into image — no runtime mutation needed | Immutable image model eliminates this class of problem |
| Cleanup workflow | Full `cleanup.yml` to tear down all resources | `make clean` locally; `helm uninstall` on cluster | Helm makes this trivial |

---

## Features the legacy system has that psa-moodle lacks

| # | Legacy feature | What it does | Gap severity |
|---|---|---|---|
| 1 | **Sysdig monitoring + MySQL exporter** | Prometheus metrics export from the database (query throughput, replication lag, connection pool), with Sysdig webhook alerts on threshold breaches | **Medium-high** — psa-moodle has no application/database metrics or alerting beyond "are pods healthy" |
| 2 | **Rocket.Chat notifications** (`notify.yml`) | Webhook fires on every workflow success/failure with color-coded messages, actor, branch, link to run | **Medium** — psa-moodle has no CI/CD notification channel at all (noted in Phase 5 docs as a gap) |
| 3 | **Scheduled weekly rebuilds** (`scheduled-rebuild.yml`) | Saturday 03:00 UTC cron triggers a full image rebuild to pick up upstream Moodle patches, base image security fixes, and plugin updates automatically | **Medium** — psa-moodle only rebuilds on code push; stale base images and unpatched dependencies drift silently |
| 4 | **Custom maintenance page** (`moodle_index_during_maintenance.php`) | User-friendly "The Learning application is currently down for maintenance" page served during deploys | **Low** — psa-moodle's atomic image rollover means downtime is seconds, not minutes. Useful for longer operations (DB migrations, Phase 7 data import) |
| 5 | **Production deploy gate with explicit confirmation** (`confirm_production` input) | Manual "type PROD to confirm" safeguard on workflow_dispatch prevents accidental prod deploys | **Low now, medium later** — psa-moodle's GitHub Environment reviewer approval partially covers this, but the explicit text confirmation is an additional speed bump |
| 6 | **`skip_deploy` option** | Build images without deploying — useful for verifying image builds in isolation or pre-staging images before a maintenance window | **Low** — achievable manually by running the build workflow alone, but not surfaced as a first-class option |
| 7 | **File migration job** (`migrate-build-files-job.yml` + `migrate-build-files.sh`) | Copies new code from a build container to the shared RWX PVC, validates completion by polling for a canary string | **Not needed** — psa-moodle's immutable images eliminated shared code volumes entirely. This is legacy complexity, not a missing feature. |
| 8 | **Additional plugins** (customcert, topcoll course format) | `mod_customcert` (custom certificates), `format_topcoll` (collapsible topics) | **Decision needed** — these may or may not be wanted in the re-platform. Worth confirming with stakeholders. |
| 9 | **Debug mode in prod config** (`?debug` query param dumps `$_SERVER` and `$CFG`) | Quick runtime diagnostics without SSH/exec | **Should NOT be carried forward** — information disclosure vulnerability. The legacy config `print_r($_SERVER)` to anyone who appends `?debug` to a URL. |
| 10 | **`list_courses.php` / `cdata-proxy.php` utility scripts** | Ad-hoc admin utilities baked into the image | **Low** — better handled via `oc exec` + Moodle CLI in the new model |

---

## The three gaps to close

### 1. Observability / Metrics / Alerting (Sysdig equivalent)

The legacy system exports Prometheus metrics from MariaDB via a sidecar exporter and sends webhook alerts through Sysdig. psa-moodle currently has:

- Backup-failure email alerts (Phase 6)
- Pod health via Kubernetes probes

What's missing:

- Database metrics (connection count, query latency, replication lag, WAL throughput)
- PHP-FPM pool metrics (active workers, request queue depth, slow requests)
- Application-level metrics (Moodle cron duration, cache hit rates)
- A dashboard (Sysdig, or whatever BC Gov now provides)
- Alerting thresholds that fire before pods are already dead

Crunchy Postgres operator exports Prometheus metrics natively via its `monitoring` spec — wiring it to whatever observability platform BC Gov Silver offers now is the path forward.

### 2. CI/CD Notifications

Legacy fired a webhook on every workflow outcome. psa-moodle's Phase 5 docs explicitly note this gap: "BC Gov no longer runs Rocket.Chat, so any channel choice is a fresh decision." A channel needs to be picked (Teams, email, GitHub webhook) and wired in.

### 3. Scheduled dependency refresh

The weekly Saturday rebuild catches:

- PHP base image CVEs (e.g. `php:8.3-fpm-bookworm` gets patched upstream)
- Moodle point-release security fixes on the `MOODLE_405_STABLE` branch
- OS package updates in the Debian layer

Without it, images only refresh when code is pushed. A scheduled workflow dispatch or Dependabot-style approach would close this.

---

## Legacy patterns to NOT carry forward

| Legacy "feature" | Why it's harmful |
|---|---|
| `?debug` query param dumps server config | Information disclosure — attacker can see DB credentials, server paths |
| `MARIADB_ALLOW_EMPTY_ROOT_PASSWORD: yes` | Unnecessary in dev, catastrophic if it leaks to prod |
| Hardcoded replication password (`replsecret`) in a ConfigMap | Should be in a Secret |
| Shared RWX code volume + file migration job | The entire reason for the re-platform — mutable code volumes cause drift |
| Redis sessions commented out in prod | Sessions hit the DB under load; legacy never finished this |
| DeploymentConfigs (OpenShift-specific, deprecated) | psa-moodle correctly uses standard Deployments |
| `error_reporting(E_ALL)` + `display_errors = 1` in remote config | Leaks stack traces to users |

---

## Summary

The legacy system is more operationally *instrumented* (Sysdig metrics, webhook notifications, scheduled rebuilds) but architecturally fragile (Galera, mutable shared volumes, sessions on disk, commented-out cache). psa-moodle is architecturally sound but still needs to close three operational gaps: **metrics/alerting**, **CI notifications**, and **scheduled base-image refresh**. Everything else the legacy does that psa-moodle doesn't is either eliminated by design (file migration, shared code PVCs) or actively harmful (debug endpoints, empty root passwords).
