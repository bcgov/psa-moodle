# Temporary quota request — 950003-prod (replatform parallel run)

> **SUBMITTED 2026-11-25** through the Product Registry (prod: 4 → 7 cores, 96 → 144 GiB; everything else unchanged).
> The text actually sent is below; the form's box takes at most 1,000 characters. It supports decision D1 in
> [replatform-950003-runbook.md](replatform-950003-runbook.md). The new stack's figures are planning numbers from the a58ce1
> PoC's admitted requests, scaled to the prod shape; prod's current state was re-read from the cluster on 2026-11-25.

## What to enter in the Product Registry (950003 → Quotas)

| Namespace | CPU (cores) | Memory (GiB) | Storage (GiB) |
|---|---:|---:|---:|
| Production | **4 → 7** (temporary) | 32 (no change) | **96 → 144** (temporary) |
| Test | no change (4) | no change (32) | no change (96) |
| Development | no change | no change | no change |
| Tools | no change | no change | no change |

- **Storage** +48 GiB is +50%, and prod's allocated storage is at 97%. The platform auto-approves storage when usage is
  over 80% and the increase is no more than 50%, so this part should be approved automatically. The budget in the supporting detail needs
  133.1 GiB, leaving about 10.9 GiB of margin. **No restore drill runs in prod during the parallel run;** restore rehearsals
  run in dev.
  - Only the aggregate `storage-quota` needs to rise. The per-class quotas already fit the new PVCs (2026-11-25):
    `netapp-file-backup` 20 → 38 of 48 GiB, `netapp-file-standard` 73.1 → 80.1 of 96, `netapp-block-standard` 0 → 15 of 96.
- **CPU** +3 cores (+75%). The platform auto-approves CPU only when the namespace's utilization rate is at least 35%. Prod
  averages 0.141 cores against 2.975 requested (about 5%), so expect **manual review** whatever the size. Review happens
  by email; the notes and supporting detail below cover follow-up questions.
- **Duration:** until legacy prod is decommissioned (estimated 4–6 weeks). We will then file a decrease back to
  4 cores / 96 GiB. Afterwards the new stack (about 2.8 cores and 40 GiB at peak) runs within the original quota.

## Text submitted (2026-11-25, 941 characters)

```
1) We're replacing our legacy Moodle stack in 950003-prod (MariaDB Galera, Redis/Sentinel) with Crunchy Postgres and Valkey, like Example 3 in your quota guide. Both stacks must run side by side for a short bail-out period after cutover, so we need a temporary increase to 7 cores and 144 GiB. We'll request the decrease back to 4 cores / 96 GiB when legacy is decommissioned (est. 4-6 weeks).
2) Prod requests 2.975 of 4 cores, with 93.1 of 96 GiB storage allocated. The new stack adds about 2.8 cores at peak (3 Crunchy Postgres instances at 400m incl. sidecars, 3 php-fpm at 200m, plus small pods) and 40 GiB of PVCs. Together: about 5.8 cores and 133 GiB. Memory fits the existing 32 GiB.
3) The new stack fits the current quota on its own; only the overlap needs more. We're not lowering legacy's requests: that restarts legacy pods, which are our fallback. Storage is sized from files actually in use (2.9 GiB, not the 8.4 GiB volume).
```

Left out to fit the limit, and covered in the notes below if asked: the usage history (0.14 cores average, 2.36-core
five-minute peak), the list of new PVCs, and restore tests running in dev.

## If Platform Services asks (notes for the submitter, not for pasting)

Questions arrive by email, and the request stays open for two weeks, so there's time to check an answer before replying.
Prod's current requests and storage were re-read from the cluster on 2026-11-25. The usage history comes from the dated
exports below, and the new stack's figures are the proof of concept's admitted requests (see the supporting detail).

- **"You use 0.14 cores on average. Why request so much?"** Quota counts **requests**, not use. Legacy's 2.975 cores of
  requests stay as they are until it is decommissioned. The new stack's 2.8 cores are its requests at peak, about half
  of them Postgres. The 2.36-core five-minute peak shows the site does burst.
- **"Lower legacy's requests instead, for example Redis's 1.5 cores."** Changing requests restarts those pods. Legacy is
  our fallback during the migration, and its Redis and Sentinel keep their state in memory without readiness probes. A
  restart of them is the riskiest step we have, so legacy stays frozen until it's decommissioned.
- **"Why three Postgres instances at 400m each?"** The platform's high-availability database guide says HA clusters need
  three pods. Each instance's 400m is the database container's 250m plus the operator's sidecars, the admitted figure
  from our running proof of concept. After cutover we measure real use and right-size before filing the decrease.
- **"Why 7 and not 6?"** 5.8 cores at peak leaves 0.2 under 6, too little for a rollout or an operator default we haven't
  measured. **If they offer 6, accept it.** Prod then runs **two** Postgres instances during the overlap, as test does
  (5.4 of 6), and moves to three after legacy is decommissioned. That changes decision G3 for prod, which is your call.
- **"Where are your usage figures from?"** OpenShift's **Observe → Metrics**, 12–26 October 2026, exported as CSV. The
  files and queries are in `artifacts/quota-evidence/2026-10-26/` (local only, not in Git); the findings are in
  [quota-evidence.md](quota-evidence.md). Graphs can be re-exported if they ask for screenshots.
- **"Legacy uses about 17.6 GiB of memory but requests 5.47?"** Legacy's five MariaDB nodes run above their requests.
  We aren't asking for memory: both stacks together request about 13 GiB of the existing 32.
- **"How long?"** Until legacy prod is decommissioned after its bail-out window and sign-off, estimated 4–6 weeks. Then
  we file the decrease, and the new stack (about 2.8 cores and 40 GiB at peak) runs within the original quota.

## Supporting detail (not for pasting)

The component breakdown behind the answers above, for follow-up questions.

**Current (950003-prod, 2026-11-25):** 2.975 of 4 CPU cores requested (1.025 free), 5.47 of 32 GiB memory requested, and
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
| Backup Jobs while running (pgBackRest backups, the nightly file backup, integrity check) | 1–2 | about 150m | about 256Mi | 0.300 |
| Short-lived configuration probe during a return | 1 | 100m | 256Mi | 0.100 |
| **New stack peak** | | | | **2.800** |

pgBackRest's backup Job pods have no `activeDeadlineSeconds`, so they count against the **long-running** quota, not the
time-bound one. We count every backup Job there to be safe. Both stacks together peak at about **5.8 cores** of requests, so 7 cores leaves about 1.2 cores for rollout
variance and operator sidecar defaults. No restore drill runs in prod during the parallel run. Memory, about 13 GiB of
requests in total, fits the existing 32 GiB.

**Storage added temporarily:**

| PVC | Class | Size (GiB) | Basis |
|---|---|---:|---|
| Moodle data (RWX) | `netapp-file-standard` | 6 | 2.93 GiB of referenced files today, plus growth |
| Postgres data | `netapp-block-standard` | 3 × 5 | Database is about 1 GiB today; WAL and vacuum headroom; three instances |
| pgBackRest repository | `netapp-file-backup` | 8 | Weekly full, daily differential and hourly incremental backups plus WAL, with 8 days of point-in-time recovery; class backed up by OCIO |
| Moodle data backup destination | `netapp-file-backup` | 10 | Nightly copies of the files the database references, plus Moodle's key and language folders, 7 retained. Files unchanged since the night before are hard links, so the volume holds one full copy (about 2.9 GiB) plus about 0.6 GiB a day of deleted or replaced content. The backup job checks free space before each run; alert at 70% |
| Valkey | `netapp-file-standard` | 1 | Cache persistence |
| **Total** | | **40** | |

Legacy prod has 93.1 GiB allocated today (95,332 MiB). Adding these 40 GiB makes **133.1 GiB**, so 144 GiB leaves about
10.9 GiB for growth, including possible growth of the legacy Moodle data volume during the bail-out window (3.7 GiB free on
it today). Restore rehearsals run in dev, not in prod, during the parallel run.
