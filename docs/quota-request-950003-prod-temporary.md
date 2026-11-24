# Temporary quota request — 950003-prod (replatform parallel run)

> **DRAFT, 2026-11-24 (revised for the v0.5 review, V507/V508; v0.6 review wording only, figures unchanged). Not
> submitted.** It supports decision D1 in
> [replatform-950003-runbook.md](replatform-950003-runbook.md). The new stack's figures are
> planning numbers, from the a58ce1 PoC's admitted requests scaled to the prod shape. Replace them with dev Pass A's
> admitted requests if those exist by submission time.

## What to enter in the Product Registry (950003 → Quotas)

| Namespace | CPU (cores) | Memory (GiB) | Storage (GiB) |
|---|---:|---:|---:|
| Production | **4 → 7** (temporary) | 32 (no change) | **96 → 144** (temporary) |
| Test | no change (4) | no change (32) | no change (96) |
| Development | no change | no change | no change |
| Tools | no change | no change | no change |

- **Storage** +48 GiB is +50%, and prod's allocated storage is at 97%, so the size criteria for automatic approval are met.
  The budget below needs 133.1 GiB, leaving about 10.9 GiB of margin. **No restore drill runs in prod during the parallel
  run;** restore rehearsals run in dev.
- **CPU** +3 cores (+75%). Prod's actual CPU utilization is far below 35%, so expect **manual review** whatever the size.
  The justification below is written for that.
- **Duration:** until legacy prod is decommissioned (estimated 4–6 weeks). We will then file a decrease back to
  4 cores / 96 GiB. Afterwards the new stack (about 2.8 cores and 40 GiB at peak) runs within the original quota.

## Paste-ready text

### 1. Why do you need to increase your quota?
We are replacing the legacy Moodle stack in 950003-prod with a new one: MariaDB Galera ×5, Redis/Sentinel and a custom proxy
are replaced by Crunchy Postgres, Valkey and immutable images. This is the platform's Example 3 pattern, a temporary
parallel run for a database migration. For a short bail-out window after cutover, both stacks must run side by side in prod,
with legacy kept frozen but running so it can take traffic back without a cold start of its Galera and Redis clusters. We
request a **temporary** increase of prod CPU from 4 to 7 cores and storage from 96 to 144 GiB, until legacy is
decommissioned. We will then request a decrease back to 4 cores / 96 GiB.

### 2. Current and desired states of the relevant OpenShift objects
**Current (950003-prod, 2026-11-23):** 2.975 of 4 CPU cores requested (1.025 free), 5.47 of 32 GiB memory requested, and
**93.1 of 96 GiB storage allocated (2.9 GiB free)**.

| Component | Replicas | CPU request each | Memory request each | Total CPU |
|---|---:|---:|---:|---:|
| MariaDB Galera | 5 | 100m | 256Mi | 0.500 |
| Redis + Sentinel (one pod) | 5 | 300m | 512Mi | 1.500 |
| redis-proxy | 5 | 50m | 32Mi | 0.250 |
| php | 3 | 100m | 128Mi | 0.300 |
| web | 3 | 100m | 192Mi | 0.300 |
| cron, backup storage, health monitor | 1 each | 50m / 50m / 25m | 256Mi / 256Mi / 128Mi | 0.125 |
| **Legacy total** | | | | **2.975** |

Over 14 days (2026-10-12 to 10-26), legacy prod averaged 0.14 cores of CPU and 17.6 GiB of memory used, with a 2.36-core
five-minute peak.

**Added temporarily (new stack, prod shape):** requests from the running PoC, including Crunchy's sidecar containers.

| Component | Replicas | CPU request each | Memory request each | Total CPU |
|---|---:|---:|---:|---:|
| web (nginx) | 3 | 50m | 64Mi | 0.150 |
| php-fpm | 3 | 200m | 512Mi | 0.600 |
| cron | 1 | 100m | 256Mi | 0.100 |
| Valkey | 1 | 50m | 128Mi | 0.050 |
| Crunchy Postgres instance (with 3 sidecars; 3 instances per platform guidance) | 3 | 400m | 1.25Gi | 1.200 |
| pgBackRest repository host | 1 | 100m | 512Mi | 0.100 |
| Rolling-update surge (one php pod) | 1 | 200m | 512Mi | 0.200 |
| Backup Jobs while running (pgBackRest full/incremental, file-backup snapshot, integrity check) | 1–2 | about 150m | about 256Mi | 0.300 |
| Short-lived configuration probe during a return | 1 | 100m | 256Mi | 0.100 |
| **New stack peak** | | | | **2.800** |

The backup Job pods have no `activeDeadlineSeconds`, so they count against the **long-running** quota, not the
time-bound one. Both stacks together peak at about **5.8 cores** of requests, so 7 cores leaves about 1.2 cores for rollout
variance and operator sidecar defaults. No restore drill runs in prod during the parallel run. Memory, about 13 GiB of
requests in total, fits the existing 32 GiB.

**Storage added temporarily:**

| PVC | Class | Size (GiB) | Basis |
|---|---|---:|---|
| Moodle data (RWX) | `netapp-file-standard` | 6 | 2.93 GiB of referenced files today, plus growth |
| Postgres data | `netapp-block-standard` | 3 × 5 | Database is about 1 GiB today; WAL and vacuum headroom; three instances |
| pgBackRest repository | `netapp-file-backup` | 8 | Weekly full, daily differential and hourly incremental backups plus WAL, with 8 days of point-in-time recovery; class backed up by OCIO |
| Moodle data backup destination | `netapp-file-backup` | 10 | Daily `rsync --link-dest` snapshots of the file store and Moodle's key and language folders, 7 retained. Unchanged files are hard links, so the volume holds one full copy (about 2.9 GiB) plus about 0.6 GiB a day of replaced content. The backup job checks free space before each run; alert at 70% |
| Valkey | `netapp-file-standard` | 1 | Cache persistence |
| **Total** | | **40** | |

Legacy prod has 93.1 GiB allocated today (95,332 MiB). Adding these 40 GiB makes **133.1 GiB**, so 144 GiB leaves about
10.9 GiB for growth, including possible growth of the legacy Moodle data volume during the bail-out window (3.7 GiB free on
it today). Restore rehearsals run in dev, not in prod, during the parallel run.

### 3. What steps have you taken to fit the application into the current quota?
- The new stack fits prod's current quota **on its own**. Only the overlap needs more, which is why the request is temporary.
- We considered shutting legacy Redis down at cutover to free about 1.75 cores. We decided against it: Redis and Sentinel
  keep their state on `emptyDir` with no readiness probes, so restarting them during an emergency return is the riskiest
  step in our rollback plan.
- We size moodledata from the files the database actually references (2.93 GiB), not the legacy volume's 8.4 GiB, which
  includes about 5 GiB of unreferenced files that stay on the legacy volume until decommission.
- The new stack runs single cron and fixed replica counts (no autoscaling) during the migration.
- Test and dev need no increase.
- At decommission, legacy's 50 GiB of Galera volumes and 1.75+ cores of Redis/proxy requests are released, and we will
  request a decrease back to 4 cores / 96 GiB.
