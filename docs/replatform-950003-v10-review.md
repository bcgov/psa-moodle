# Eighth review of replatform 950003 DRAFT v1.0

- **Reviewed:** [replatform-950003-runbook.md](replatform-950003-runbook.md), DRAFT v1.0, commit `212a655`.
- **Date:** 2026-11-25, America/Vancouver; cluster observations continued into 2026-11-26 UTC.
- **Reviewer:** Codex.
- **Disposition:** Do not execute v1.0 as written. Continue preparation, then proceed with a narrowly scoped empty
  dev Pass A after correcting isolation and deployment bootstrap and establishing a feasible rehearsal capacity plan.
  Test and production cutovers remain no-go.

This document records the review already delivered in chat. Findings refer to `212a655`; subsequent implementation
changes, including commit `2652c76`, have not been reassessed here.

Keeping legacy running, preserving the frozen database, returning into `moodle_bailout`, pinning builds and fencing
through infrastructure remain appropriate choices. The findings concern implementation gaps in those promises.
There are **four blockers, nine major findings and one minor finding**, plus a backup-alert configuration correction.
The accepted reviewer-access risk, complete-site recovery objective and post-commit return model remain accepted inputs.

## Scope and verification

The review covered the runbook, previous reviews, chart, deployment workflow, migration and recovery scripts, relevant
legacy Moodle source and platform documentation. The owner explicitly authorized read-only `oc` verification.

Cluster activity consisted of resource queries and lightweight `SELECT` and `SHOW` statements through the existing
PHP containers. These SQL checks used the database driver directly without booting Moodle. No cluster resources,
application data, workflows or configuration were changed. Credentials and Route private keys were not printed.

Local verification included:

- Helm lint for the three 950003 values files and rendering precommit, commit and fenced states, with a synthetic
  alert recipient. The renders were inspected for storage allocation, database roles and network permissions.
- A disposable PostgreSQL 15.15 container with networking disabled and synthetic application/backup roles, reproducing
  the drain visibility failure in V1001. No user data was mounted.
- The backup gate's actual jq expression evaluated against synthetic archive metadata, reproducing V1002.
- A copy of `state-restore.sh` with its capture directory redirected to a temporary fixture and every `oc` call
  replaced by a local mock, reproducing V1005's command ordering. No cluster command ran in this test.
- The unchanged phase-8 coverage logic evaluated against a synthetic corrupted prior file, reproducing V1010.
- The dump allowlist evaluated against a synthetic multi-statement line, reproducing V1014. Only its stderr sink was
  adapted to avoid a macOS sandbox restriction on process-substitution output; the validation logic was unchanged.

These checks are not full Moodle concurrency tests or successful paired PostgreSQL restore rehearsals. Temporary
fixtures and disposable containers were removed. The original review changed no repository files; this document was
subsequently added at the owner's request. The runbook and implementation remain untouched by this review.

## Findings

Code line references below refer to the reviewed commit.

| ID | Severity | Section and step | Concrete failure scenario | Suggested change |
|---|---|---|---|---|
| V1001 | **Blocker** | §8.1 C8 pause/drain; `scripts/ops/moodledata-backup.sh:113` | The restricted `moodle_backup` role cannot see other users' `backend_type`. Its filter therefore excludes active Moodle sessions. Confirmed in PostgreSQL 15: the backup query returned **0** while an active Moodle connection existed. The supposedly frozen inventory can change during capture. | Give the drain a narrowly authorized way to observe these sessions. Test using the actual backup role, including a long-running request. |
| V1002 | **Blocker** | §8.1 C8 database gate; `scripts/ops/moodledata-backup.sh:195` | The gate compares the maximum WAL filename lexically across archive entries. It does not use the supplied timeline argument or establish the live database's identity. A synthetic target on timeline **2** passed using an archive maximum on timeline **3**. That does not prove the named restore point is recoverable. | Match database identity, repository/archive identity, backup ancestry and the required WAL chain. Prove rejection of unrelated timelines and recovery across failover. |
| V1003 | **Blocker** | §8.1 C9/C15; `chart/psa-moodle/templates/networkpolicy.yaml:209` | `networkPolicy.externalEgress=off` is not implemented. Rendering with it still allows every release pod outbound HTTPS. Conversely, `moodledata-backup` is missing from PostgreSQL and SMTP egress selectors, and php/cron lack SMTP permission after commit. | Implement C9/C15 and test the rendered permissions for each component. The existing namespace policies do not supply the missing application egress controls. |
| V1004 | **Blocker** | §8.1 C8, §13.2–13.3; `chart/psa-moodle/templates/postgrescluster.yaml:59`, `postgres-init-configmap.yaml:19`, `cronjob-moodledata-backup.yaml:1` | Precommit disables `backup.moodledata`, removing its database role, backup PVC and initialization grant. Thus §13.2's `GRANT SELECT ... TO moodle_backup` targets a nonexistent role, and S12 cannot seed the specified backup volume. Enabling everything at commit is too late; editing completed initialization SQL does not automatically rerun it. | Provision storage, role and grants before commit. Control scheduling separately with suspension, and verify grants explicitly. |
| V1005 | **Major** | S14, §13.4 and abandonment; `ops/replatform/state-restore.sh:40` | Restoration starts cron and restores unrestricted Routes before transitioning maintenance mode. A mocked execution reproduced test's unrestricted `--disable` → `--enableold` interval. Also, the default `prereturn` restore changes environment/configuration as well as Routes, contrary to the abandonment procedure's intended separation. | Keep ingress fenced until maintenance is restored. Make restore scopes explicit in every executable command, especially `RESTORE_SCOPE=routes` during abandonment. |
| V1006 | **Major** | §14 cleanup; `ops/replatform/legacy-cleanup.sh:46` | `command <> 'Sleep'` checks executing SQL, not running PHP requests. A request waiting on HTTP or filesystem work can have a sleeping database connection. Cleanup can declare it drained and begin switching consumers while it still runs. | Prove request/process completion or count all relevant application connections. Recheck prerequisites when resuming interrupted cleanup. |
| V1007 | **Major** | §9 rehearsal capacity; `chart/psa-moodle/values-950003-dev.yaml:33` | Live dev has **28.66 GiB free**. Rendered storage is **20 GiB precommit and 30 GiB with backups**, before a Pass C fixture or restore target. The complete rehearsal does not fit the stated quota. | Write a storage budget for each rehearsal state, including retained PVCs, fixture and restore targets. Reduce sizes or establish an approved capacity/cleanup sequence before starting. |
| V1008 | **Major** | §8.1 C13; `.github/workflows/deploy-950003.yml:85` | The first precommit deployment requires the database Secret and populated database before Helm creates the stack. Later, the commit deployment reloads the checked-in values, including the temporary `wwwroot`, undoing CP3's public-host setting. | Add an explicit bootstrap path and preserve the complete approved deployment configuration through precommit, commit and fence transitions. |
| V1009 | **Major** | J1 pause limits; `scripts/ops/moodledata-backup.sh:140` | The capture deadline is checked between files. A blocked final `cp`, checksum, SQL call or durable-directory copy can exceed it. The cron watchdog can then reopen the site while the backup remains alive and continues toward publication. | Bound individual operations and the overall pause. Invalidate the run if its maintenance fence expires or disappears. Test stalled operations, not only terminated pods. |
| V1010 | **Major** | §8.1 C8 coverage; `scripts/ops/moodledata-backup.sh:163` | Inherited files are checked for existence without checking size or content. The unchanged coverage code accepted a corrupted prior file under its original content-hash filename. Corruption can propagate into newly published sets. | Verify inherited content against its hash before certifying the set. Test present-but-damaged files as well as missing files. |
| V1011 | **Major** | J4 retention/alerts; `scripts/ops/moodledata-backup.sh:230` | `ALERT_DAYS` and `ESCALATE_DAYS` are declared but unused. Pair expiry is assessed only after a successful new publication. Repeated failures or skipped runs therefore do not implement the promised three/five-day escalation. Several shell failures also bypass `die()` and its alert. | Monitor the age and recoverability of the newest usable pair independently of successful backup runs. Alert on unhandled failures and missed schedules. |
| V1012 | **Major** | S12 paired restore; `scripts/ops/restore-paired.sh:158` | The canary is encrypted and decrypted after restoration, proving only that the restored key works with itself. Missing-file validation compares counts, allowing a different missing hash to replace a known gap without failing. | Decrypt a canary stored before backup. Compare exact inventory and gap identities against the restored database. |
| V1013 | **Major** | S7, §8.3 local conversion; `ops/replatform/local-pipeline.sh:119` | `e7_uninstall()` runs `upgrade.php --non-interactive` before the pipeline's version check, even when GitHub sync is already absent. An older or wrong dump can be upgraded first and subsequently pass the compatibility check. | Verify core and plugin versions before any uninstall/hash-refresh operation. Restrict the permitted refresh to the documented changes. |
| V1014 | **Minor** | RB13 dump allowlist; `ops/replatform/bailout-dump-check.sh:26` | The checker accepts an entire line once its opening `INSERT ... VALUES` matches. A synthetic line with an appended `INSERT INTO moodle.config ...` was accepted. The restricted import account remains the important protection; this did not demonstrate a frozen-database write. | Validate complete statements, including statement boundaries outside quoted data, or narrow the checker's stated guarantee. Retain the restricted account. |

## Evidence for the principal safety findings

### V1001 The backup role cannot see the field used by the drain

The isolated PostgreSQL 15.15 test created two login roles, `moodle` and `moodle_backup`, and held a synthetic
`moodle` connection in `pg_sleep()`. Querying as `moodle_backup` returned:

```text
usename: moodle
backend_type: NULL
runbook_drain_count: 0
actual_moodle_client_count, observed as administrator: 1
```

The chart grants the backup role permission to create a restore point and plans a separate grant to read `mdl_files`.
Neither grant supplies the visibility required by the drain predicate. PostgreSQL documents restricted visibility of
other users' sessions; its implementation specifically hides the backend-type field without the appropriate role
privileges. This is why a test run as a local superuser can pass while the deployed role behaves differently.
[PostgreSQL 15 statistics documentation](https://www.postgresql.org/docs/15/monitoring-stats.html),
[PostgreSQL 15 activity implementation](https://github.com/postgres/postgres/blob/REL_15_STABLE/src/backend/utils/adt/pgstatfuncs.c#L759).

### V1002 A higher timeline number is not proof of the required archive

The actual jq gate was supplied with target WAL `00000002000000000000000A`, target LSN `0/A000000`, timeline `2`,
a qualifying base-backup stop LSN and an archive maximum of `000000030000000000000001`. It returned:

```text
ok test-base 111
```

The timeline argument is passed to jq but never used by its expression. The archive maximum is selected across all
archive entries, and the recorded system identifier is taken from repository metadata rather than independently
matched to the live source. A passing comparison therefore cannot certify the required restore target. This was a
synthetic metadata test, not an actual restore attempt.

### V1003 and V1004 Rendering reveals missing controls before any deployment

With `networkPolicy.externalEgress=off`, the rendered HTTPS policy still selects all pods of the release and permits
TCP 443 to `0.0.0.0/0`. The PostgreSQL egress list contains php, cron, install, backup-integrity and restore-rehearsal,
but not moodledata-backup. The SMTP list likewise omits moodledata-backup and the application php/cron components.

The precommit PostgresCluster contains only the `moodle` user. The backup role and PVC appear only when
`backup.moodledata.enabled=true`. The role's restore-point grant is also conditional inside initialization SQL.
Crunchy records successful initialization in cluster status and does not rerun that SQL while the status remains set;
adding the grant to the ConfigMap at commit does not establish that it has executed.
[Crunchy database initialization documentation](https://access.crunchydata.com/documentation/postgres-operator/v5/tutorial/customize-cluster/).

### V1005 The observed restore order contradicts S14

A synthetic test capture specified web maintenance, one cron replica and an unrestricted legacy Route. The mocked live
state had CLI maintenance, cron at zero and a restricted fence Route. The restore script issued these mutations in order:

```text
1. Scale legacy cron to 1.
2. Replace the Route with its unrestricted captured version targeting legacy web.
3. Run maintenance.php --disable.
4. Run maintenance.php --enableold.
```

This directly reproduces the interval S14 says must remain fenced. Separately, the restore script defaults to restoring
replicas, environment, CronJobs, ConfigMaps, Routes and maintenance. The abandonment command must specify its intended
Routes-only scope, rather than relying on the accompanying prose.

### V1010 and V1012 Verification must identify the content it certifies

The coverage test created a filename equal to the SHA-1 of `original file`, then placed different bytes under that
name in the previous set. The actual phase-8 code linked it into the new staging folder and accepted coverage with
exit status zero. Its resulting content hash did not match the filename.

The paired restore's encryption round trip is a separate issue: encryption and decryption performed after restoration
can succeed with the wrong restored key. The planned canary must be encrypted before backup and decrypted afterwards.
Likewise, an allowed number of missing files is weaker than the specified allowlist of missing content hashes.

## Additional backup-alert configuration correction

The 950003 profiles schedule weekly full backups, but `backup.integrity.maxFullBackupAgeHours` remains at the default
**30 hours**. The integrity checker will consequently raise predictable false alarms between healthy weekly full
backups. Align the threshold with the weekly schedule and separately monitor the expected differential/incremental
cadence and usable paired-set age.

## Live facts reverified

| Check | Result | Consequence |
|---|---|---|
| Legacy Moodle versions | Dev `2024100715`; test `2024100711.03`; prod `2024100711.04`. | The documented rehearsal build matrix matches the live database settings. |
| Maintenance settings | Dev `0`, test `1`, prod `0`. | Test's web-maintenance starting state still requires exact, fenced restoration. Dev's public Routes remain on its fence service. |
| Galera | All three StatefulSets report 5/5 ready. The database node reached in each namespace reports cluster size 5, Primary, Synced and ready. | Consistent with the updated baseline; this is not a full five-node consistency or failover test. |
| Long-running CPU requests | Dev `1.430/4`, test `1.375/4`, prod `2.975/4` cores. | Dev has 2.570 cores free. Time-bound quota was unused. |
| Aggregate allocated storage | Dev **68,958 MiB**, test **78,948 MiB**, prod **95,332 MiB**, each against 96 GiB. | Dev has **28.66 GiB** free. Test plus its rendered 16 GiB is about **93.10 GiB**. Prod plus 40 GiB is about **133.10 GiB**. |
| Prod temporary quota | Still **4 cores / 96 GiB**. | The requested increase has not been applied. |
| Fence workloads | Dev running; test absent; prod desired replicas zero. | Test/prod fence provisioning remains a prerequisite. |
| Health monitors | Desired replicas one in all three namespaces, with `MANUAL_MODE=true`. | E4's scaling step remains outstanding. |
| Public Routes | Test and prod target legacy web. Prod retains both public Routes and its custom certificate. | The recorded cutover routing baseline remains applicable. |

## K1 and the execution recommendation

The two-night soak is reasonable after the implementation defects are corrected. Eight accelerated backup runs
exercise rotation, but they do not exercise eight days of retention or stale-backup escalation. Include explicit
age/expiry tests, use the real restricted backup role and require the production-sized paired restore and return
rehearsals to pass. A green chart lint or a successful superuser-backed local test does not satisfy those gates.

Proceed in this order:

1. Correct application/operations egress and the deployment bootstrap, and establish a feasible dev capacity plan.
2. Run a narrowly scoped empty Pass A to validate coexistence and the repaired controls.
3. Correct and demonstrate the relevant backup, rollback and return gates before loading real-data fixtures.
4. Complete the runbook's required clean rehearsals, paired restore and owner/reviewer sign-off before scheduling
   test or production cutover.
