# Phase 6 — Backups, restore rehearsal, and the April-2026 integrity fix

This is the structural fix for the failure mode Warren documented on 2026-04-23/24: backups that *looked* successful but were either zero-byte, truncated, or missing critical Moodle tables (`sessions`, `task_*`). Recovery in test only worked because an older intact dump happened to still be on disk. Prod was running the same pipeline.

Phase 6 doesn't try to patch the old `backup.sh` — that's gone with Galera. It rebuilds the backup story around **operator-driven backups + automated content verification + scheduled restore rehearsal**.

---

## What's actually new in Phase 6

The chart already had a pgBackRest configuration (Phase 3) — daily full, hourly incremental, in-cluster PVC repo. That part is operator-managed and we trust the operator to run the schedule.

What Phase 6 layers on top:

| New resource | What it does | Acceptance test |
|---|---|---|
| `Containerfile.ops` | Tiny alpine image: `oc` + `swaks` (SMTP CLI) + the four scripts in `scripts/ops/` | `make build` produces `psa-moodle-ops:<tag>` |
| `cronjob-backup-integrity` | **Daily.** `pgbackrest info` + `pgbackrest verify` against the repo, plus row-count assertions on canonical tables in the live primary (`mdl_sessions`, `mdl_task_*`, etc.). Emails on any failure. | Deliberately break a backup (see below) — alert fires within one cron cycle |
| `cronjob-restore-rehearsal` | **Weekly (test/prod only; disabled in dev).** Spins up a temporary `PostgresCluster` from the pgBackRest repo, runs a SQL smoke test, tears it down. Emails on both pass and fail (heartbeat). | Three consecutive successful weekly runs before any prod cutover |
| `cronjob-moodledata-snapshot` + `-prune` | **Daily.** `VolumeSnapshot` of the moodledata RWX PVC; companion job prunes snapshots older than `retentionDays`. Skips gracefully if the storage class has no VolumeSnapshotClass. | `oc get volumesnapshot` shows a new snapshot per day; old ones pruned |
| `rbac-ops` | ServiceAccount + Role + RoleBindings the ops CronJobs need (exec into Crunchy/Moodle pods, manage `PostgresCluster` + `VolumeSnapshot`, read pguser Secret) | `oc auth can-i create postgrescluster --as=system:serviceaccount:a58ce1-dev:psa-moodle-ops` returns `yes` |

All four CronJobs use the same `psa-moodle-ops` image and the same `psa-moodle-ops` ServiceAccount — one ops container, four scheduled invocations.

---

## Alert flow

All four CronJobs share `scripts/ops/alert.sh`. It calls `swaks` against `apps.smtp.gov.bc.ca:25` (unauth'd BC Gov gov-net relay — no creds, works from any Silver pod that has egress to the gov network).

```
   CronJob failure       alert.sh        apps.smtp.gov.bc.ca       backup.alerts.to
        │                    │                    │                       │
        ▼                    ▼                    ▼                       ▼
     bash trap   ──►   swaks --server   ──►   gov-net relay  ──►   recipient inbox
                       --port 25                                   (per env)
                       --from psa-moodle-noreply@gov.bc.ca
                       --to $ALERT_TO
                       --h-Subject "psa-moodle: ..."
                       --body "..."
```

`backup.alerts.to` is required (Helm `required` template function blocks install if unset). Configured in `values-dev.yaml` and `values-test.yaml`; comma-separated for multiple recipients.

---

## The deliberate-corruption test (Phase 6 acceptance)

The whole point of this work is "would we have caught Warren's April incident?" The answer has to be yes, demonstrably. Run this in `a58ce1-test`:

### Test 1 — Stale full backup

Force `pgbackrest info` to report a too-old full backup by simulating a window with no completed full:

```sh
# Pause the scheduled fulls (set MAX_FULL_BACKUP_AGE_HOURS to a tiny number temporarily)
oc -n a58ce1-test patch cronjob psa-moodle-backup-integrity --type=json \
  -p '[{"op":"replace","path":"/spec/jobTemplate/spec/template/spec/containers/0/env/-","value":{"name":"MAX_FULL_BACKUP_AGE_HOURS","value":"1"}}]'

# Trigger the integrity job manually instead of waiting for the daily.
oc -n a58ce1-test create job --from=cronjob/psa-moodle-backup-integrity force-stale-1

# Expect:
#   - Job fails (non-zero exit)
#   - Email lands in `backup.alerts.to` inbox within a few minutes
#   - oc logs show "last full backup is Nh old (threshold 1h)"
```

Revert the patch after.

### Test 2 — Required table missing in the live DB

This is the Warren April scenario, mirrored:

```sh
# Drop a canonical table from the live DB (test env only — never prod!).
oc -n a58ce1-test exec deploy/psa-moodle-php -- psql -c "DROP TABLE mdl_sessions;"

oc -n a58ce1-test create job --from=cronjob/psa-moodle-backup-integrity force-missing-table

# Expect:
#   - Job fails
#   - Email subject includes "backup integrity FAIL"
#   - Body includes "required table missing in live primary: mdl_sessions"

# Restore the table by running upgrade.php — Moodle recreates missing core tables.
oc -n a58ce1-test exec deploy/psa-moodle-php -- php /var/www/html/admin/cli/upgrade.php --non-interactive
```

### Test 3 — Restore rehearsal smoke

Trigger the weekly rehearsal manually:

```sh
oc -n a58ce1-test create job --from=cronjob/psa-moodle-restore-rehearsal force-rehearsal-1

# Watch:
oc -n a58ce1-test get postgrescluster -w
# Expect: a temporary "psa-moodle-pg-rehearsal" cluster appears, primary
#         becomes Ready (~5 min), then the cluster is deleted.

# Email arrives with subject "psa-moodle: restore rehearsal OK (<seconds>s)" — this is the
# weekly heartbeat. If you get "FAIL" instead, log tells you which check tripped.
```

### Acceptance for Phase 6

- [ ] Test 1 (stale full) fires an alert email — **caught it**
- [ ] Test 2 (missing canonical table) fires an alert email — **this is the Warren April fix proving itself**
- [ ] Test 3 (manual rehearsal) emails a single-line OK
- [ ] Three consecutive scheduled weekly rehearsals pass (without manual intervention) before any production conversation
- [ ] `oc get volumesnapshot` shows daily moodledata snapshots and old ones pruning at `retentionDays`

When the boxes are ticked, Phase 6 is done. Production cutover (Phase 8) is still a separate approval and inherits the green Phase 6 evidence as part of its readiness check.

---

## Operational notes

### How recipients get added

Edit `values-<env>.yaml`:

```yaml
backup:
  alerts:
    to: "ops-oncall@example.org,sec-team@example.org"
```

…then re-run `deploy.yml` (or `helm upgrade --install` locally). Takes effect at the next CronJob tick — no pod restart needed because the env block is rebuilt on each Job.

### What happens if `apps.smtp.gov.bc.ca` is unreachable

`swaks` errors but the script doesn't abort — each recipient is a separate swaks invocation wrapped in `|| echo WARNING`. The Job still fails non-zero (because the underlying check failed) and `oc get jobs --field-selector status.successful=0` will show it. The `failedJobsHistoryLimit: 7` on each CronJob keeps a week of evidence around.

If SMTP is broken for an extended period, the rehearsal's "OK heartbeat" stops landing — that's the second signal. The dashboard query you want is "no `restore rehearsal OK` email this week → investigate."

### Rehearsal duration in real numbers

In Phase 6 prep against a dev-size DB, the rehearsal takes 4–7 minutes. Sized to prod (Discovery Phase 0's DB-size value), expect 15–25 min. The `REHEARSAL_TIMEOUT_SECONDS` default of 1800s (30 min) is sized for prod-shape data — drop to ~600s in dev if you want faster failure signals.

### What this does NOT cover

- **Application-state consistency.** The rehearsal proves the DB restores cleanly and contains the expected tables/rows. It does NOT prove that running Moodle against the restored data would boot — that requires standing up a temporary php pod, which is gold-plating until/unless someone asks for it. The SQL-level checks catch every failure mode from the April 2026 incident.
- **moodledata file content checksums.** Snapshots capture the volume; we don't verify individual file integrity. If snapshot-restore-and-diff against the live volume becomes a requirement, it lives in Phase 8 prep.
- **Cross-region DR.** Out of scope — everything stays in Silver.

---

## What changed since Phase 3

The Phase 3 chart already provisioned pgBackRest via the `PostgresCluster` CR. Phase 6 doesn't rewrite any of that. The additive changes:

- `values.yaml` gained a `backup:` block
- `image.ops.name: ops` added to image refs
- new `_helpers.tpl` block: `psa-moodle.opsEnv`
- new templates: `rbac-ops.yaml`, `cronjob-backup-integrity.yaml`, `cronjob-restore-rehearsal.yaml`, `cronjob-moodledata-snapshot.yaml`
- new files: `Containerfile.ops`, `scripts/ops/*.sh`
- Makefile builds and pushes the ops image alongside php/web/cron

Phase 5's CI consumes all of this through the existing `make push` target — no workflow changes required.
