# Seventh review of replatform 950003 DRAFT v0.8

- **Reviewed:** [replatform-950003-runbook.md](replatform-950003-runbook.md), DRAFT v0.8, commit `e39f462`.
- **Date:** 2026-11-25, America/Vancouver.
- **Reviewer:** Codex.
- **Disposition:** Continue Phase 1. Do not approve a test or production cutover yet. The revised abandonment procedure
  addresses the previous ordering findings, but the new live backup protocol still permits an incomplete recovery set
  and introduces an unsafe trash-purge race. The live dev build also needs an explicit rehearsal plan.

There are **two blockers, three major findings and one minor correction** below. Missing Phase 1 implementation is not
itself a finding. The accepted reviewer-access risk, 24-hour complete-site recovery objective, quota decisions and
post-commit return model remain accepted inputs.

## Scope and verification

This pass covered the full runbook, its previous review, the chart and recovery scripts, the legacy repository and
deployed Moodle source, and the relevant platform documentation. The owner's instruction for this review superseded
the document's older desk-review restriction.

Cluster activity was read-only: resource queries, source-file reads, filesystem free-space checks, and lightweight
`SELECT` and `SHOW` statements. No Moodle CLI application commands, configuration changes, backup jobs, restores,
failovers, workflow changes or workload mutations were performed. Passwords stayed inside their existing containers;
Secret values and Route private keys were not printed or saved.

Two source-derived filesystem models ran locally with synthetic content. They reproduce the counterexamples below;
they are **not** full Moodle concurrency tests, PostgreSQL restore tests or tests of the eventual backup image. Their
temporary fixtures were removed. This review file is the only repository addition; the runbook is unchanged.

## Findings

| ID | Severity | Section and step | Concrete failure scenario | Suggested change |
|---|---|---|---|---|
| V801 | **Blocker** | §8.1 C8 steps 1–3, lines 805–818; §8.4 step 8 | A hash committed after the inventory query but before L is absent from the verification inventory. Moving it between `filedir` and `trashdir` around the three scans can omit it from both copied trees. The coverage check passes even though recovery to L needs the missing file. | Bind the required-hash inventory to the actual recovery target and protect that set until captured. Use a coordinated writer drain/freeze, or a proven pinning protocol. Verify coverage of the target's references, including commits between inventory and L and repeated moves during copying. |
| V802 | **Blocker** | §8.1 C8 step 5, lines 821–823; §5.3 file-creation assumptions | An in-flight `create_file_from_storedfile()` has read a source row. Another request deletes its last reference; the backup's fresh inventory sees none and purges the captured hash from trash. The first request then inserts a new reference without writing file content. Live Moodle now references missing content. | Do not purge live trash on the strength of a reference query alone. Coordinate purge with all file writers and in-flight requests, or establish a supported retention/pinning protocol. Correct the claim that every new reference writes a fresh copy. |
| V803 | **Major** | §8.1 C8 concurrency and staging, lines 805 and 835–840 | A manual retry or duplicate worker overlaps the scheduled job. Both use `incoming/`; one can remove the other's staging directory, rotate its inputs, or purge live trash while the other is capturing. `concurrencyPolicy: Forbid` is not a global execution lock. | Require mutual exclusion across every invocation, held through rotation, capture, publication and purge. Use owned staging directories and safe stale-run recovery. Prove a second invocation cannot mutate either job's data. |
| V804 | **Major** | §8.1 C8 target/publication, lines 806–820; §8.3 recovery manifest and restore, lines 932–942 | File verification succeeds while WAL needed to reach L remains unarchived. The set is published as usable, then loss of the database storage leaves it unable to reach its declared target. A bare LSN also omits timeline and boundary semantics. | Before publication, verify a usable base backup and the archived WAL chain through the exact target. Record the database identity, timeline, base/backup chain and target semantics; enforce them during restore and retain them with the file set. |
| V805 | **Major** | §8.2 C10, lines 872–880; §9 prerequisites and Pass B, lines 1109–1132 | Live legacy dev is Moodle **4.5.15 / 2024100715**, while the specified migration images are **4.5.11+ / 2024100711.03 and .04**. Pass B cannot use either image against dev's current source without violating S7. A restart proof using dev's existing code also does not establish that the older test/prod recovery packages work. | Define the rehearsal build and fixture explicitly. Use an exact dev build for dev-source exercises, and separately prove the actual test/prod images and recovery packages against matching isolated fixtures in dev. Alternatively prepare a matching dev fixture as its own approved change. Never downgrade the current database in place. |
| V806 | **Minor** | §8.3 heading, line 903; recovery tooling at lines 932–942; Phase 5 | The entire `ops/replatform/` directory is designated for deletion after Phase 5, but it also contains the recurring snapshot/manifest tooling and `restore-paired.sh`, which remain necessary after legacy is gone. | Move ongoing backup and restore tooling into a maintained operations location before decommission. Delete only migration-specific tools, and prove recovery from the retained release artifacts afterwards. |

## V801 The checked inventory is not the recovery inventory

Using one database session does not make two successive reads represent the same instant. More importantly, the
runbook explicitly permits commits between the inventory query and L and relies on the directory scans to capture
their content. Its verification never checks those additional hashes.

The three scans do not establish a snapshot of the union of two directories that remain mutable. This counterexample
needs no trash purge and leaves the live source healthy:

| Order | Activity | Location of hash X |
|---|---|---|
| 1 | Read inventory I, containing the existing files but not X. | X does not exist yet. |
| 2 | Upload X and commit its reference; then record L. The database at L references X. | `filedir` |
| 3 | First `trashdir` scan completes. | `filedir`; not copied. |
| 4 | A metadata-copy request reads X's source row. Another request deletes the last committed reference. | Moves to `trashdir`. |
| 5 | The `filedir` scan passes X's path. | `trashdir`; not copied. |
| 6 | The pending metadata copy inserts a reference. Reading that file invokes `recover_file()`. | Moves back to `filedir`. |
| 7 | The second `trashdir` scan completes. | `filedir`; not copied. |
| 8 | Verify every hash in I. All are present, so the set is published. | X is absent from the backup, but required at L. |

The deployed production code supports these operations:

- `lib/filestorage/file_storage.php`, `create_file_from_storedfile()` at line 1095, reads an existing row and creates a
  new metadata record without copying its physical content.
- `lib/filestorage/file_system_filedir.php`, `remove_file()` at line 287, moves unreferenced content to trash.
- The same file's `recover_file()` at line 243 moves content from trash back to `filedir` when it is needed.

The local model used a nonempty inventory with one existing hash and one additional hash committed before L. It
reported **zero missing inventory hashes, one missing target hash, and zero missing live-source hashes**. Thus a healthy
source and a passing inventory check do not prove the published set can restore its own target.

Simply wrapping the inventory query in a repeatable-read transaction does not resolve the mismatch with a later WAL
position. Nor does adding a fixed number of directory passes prove coverage under arbitrary movement.

**Close with:** an invariant that the verified inventory includes every reference at the enforced database target.
A straightforward design is to drain all application writers, establish the target and required set, and copy or
physically pin the required content while it cannot move. An online design needs an equivalent proof. Demonstrate the
timeline above with the deployed file APIs and the chosen database recovery method before relying on it.

Also correct §8.4 step 8.1: if the last reference is deleted and its content purged **before both inventory and L**, that
hash is not required at L. Turning off trash retention would not make the specified coverage check fail. The negative
test must arrange for the missing hash to be required at the actual recovery target.

## V802 A fresh reference query does not make live purging safe

The runbook's statement that a newly referenced hash always receives fresh bytes in `filedir` applies to the inspected
upload paths, but not to all Moodle file creation. `create_file_from_storedfile()` copies metadata and can remain in
flight across another request's deletion and the backup's inventory query.

The relevant sequence is:

1. A file-copy request reads the original file record and retains its hash in memory.
2. Another request deletes the last reference, moving its bytes into trash.
3. The backup has captured those bytes, and its fresh reference inventory contains no reference to them.
4. The backup deletes the live trash file under C8 step 5.
5. The first request inserts its copied metadata. It does not write fresh content.

The local model ended with a live reference and no corresponding file in either live tree. The bytes were in the backup,
so manual recovery may be possible, but the backup job has still broken a live file. A later coverage check detects the
damage after it occurs.

This behavior is also anticipated by deployed `lib/filestorage/file_system.php`, `is_file_removable()` around line 227:
its reference check allows for concurrent reuse and relies on the trash copy for recovery. Purging that copy needs a
stronger condition than the absence of a reference at one query instant.

**Close with:** a purge procedure that accounts for in-flight metadata copies, uploads, deletes and recovery reads.
Draining and fencing file writers during purge is a direct solution within the existing exact-code constraint. A lock
used only by backup jobs cannot coordinate Moodle requests that do not take that lock. Rehearse this race separately
from backup-job overlap. Apply live-volume space monitoring too, because disabling Moodle's cleanup makes continued
backup/purge operation necessary for the application's free space.

## V803 Prevent overlap at the worker level

Kubernetes limits `Forbid` to Jobs created by the same CronJob; it also documents approximate scheduling and the need
for idempotent jobs. It does not provide a general mutex for scheduled jobs, manual invocations and recovery retries.
[Kubernetes CronJob documentation](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/#concurrency-policy)

Here overlap has destructive consequences: the next worker removes supposedly stale `incoming/`, and each successful
worker can purge the live source used by another worker. This matters beyond duplicate notifications or wasted work.

**Close with:** a single effective owner of rotation, staging, capture, publication and purge, with defined behavior
after worker death or lost ownership. Stage the manifest with the files and publish a complete set atomically. Exercise
two simultaneous invocations and an interrupted owner in dev. Confirm that the second worker cannot remove active
staging or purge during another capture. Keep `Forbid` as an additional scheduling control.

## V804 Verify the database half before publishing the pair

`pg_current_wal_lsn()` reports a write position; reading it does not prove its WAL is already in the backup repository.
PostgreSQL archives completed segments, and recovery with an explicit target fails if the available archive ends before
that target. The existing PoC has `archive_timeout = 1min`, verified read-only, so an ordinary short file copy can finish
before the target segment is archived even when archiving is healthy.
[PostgreSQL WAL functions](https://www.postgresql.org/docs/15/functions-admin.html#FUNCTIONS-ADMIN-BACKUP),
[continuous archiving](https://www.postgresql.org/docs/15/continuous-archiving.html),
[recovery target behavior](https://www.postgresql.org/docs/15/runtime-config-wal.html#RUNTIME-CONFIG-WAL-RECOVERY-TARGET)

The PoC's current archive success is useful operational evidence; it does not supply the missing publication gate in C8.
That gate must establish recoverability using the retained repository, independently of live database disks.

An LSN also needs a defined timeline and boundary. pgBackRest defaults to inclusive recovery. PostgreSQL 15 compares the
target with WAL record start positions, whereas `pg_current_wal_lsn()` describes the current write endpoint. The specified
command therefore should not be treated as an exact snapshot boundary without a demonstrated convention. A named restore
point is another option, but still needs a matching file inventory and an archive-readiness check.
[pgBackRest restore options](https://pgbackrest.org/command.html#command-restore),
[PostgreSQL 15 recovery implementation](https://github.com/postgres/postgres/blob/REL_15_STABLE/src/backend/access/transam/xlogrecovery.c)

**Close with:** a manifest identifying the database, timeline, backup chain, exact target and inclusive/exclusive or
named-point semantics. Before marking a pair usable, verify the required archive chain is available. Coordinate
retention with the oldest retained usable file set; eight days alone cannot cover arbitrarily old file sets retained
after repeated file-backup failures. Rehearse delayed archiving, an unavailable source, boundary transactions and a
timeline change. Keep a previous usable pair until the replacement is complete.

## V805 Make dev a representative and compatible rehearsal

Read-only SQL returned `version = 2024100715` and `release = 4.5.15 (Build: 20261005)` in `950003-dev`. Reading dev's
`version.php` confirmed the same code version. Test and production remain on the two older versions specified in C10.

This is a concrete mismatch between Pass B's chosen source and the enumerated image builds. S7 correctly requires the
pipeline to stop. It should remain strict; relaxing that check would turn a migration rehearsal into an upgrade or
downgrade exercise.

**Close with:** an explicit build/fixture matrix naming the legacy code, source database, conversion runtime and target
image for each rehearsal. Current dev can be exercised with its own exact image. Before test/prod sign-off, also start
fresh legacy pods from their actual recovery packages and perform the return using their matching code and data in dev.
Pass C's production-sized forward load is useful, but it must not silently return that database to newer dev code.

## Live facts reverified on November 25

| Check | Result | Consequence |
|---|---|---|
| Long-running CPU requests | Dev **1.430/4**, test **1.375/4**, prod **2.975/4** cores. Time-bound quota unused. | Dev's free CPU is **2.570**, rather than §5.4's dated 2.670. Test/prod baselines still match. |
| Aggregate allocated storage | Dev **68,958 MiB**, test **78,948 MiB**, prod **95,332 MiB**, each against 96 GiB. | Test plus 16 GiB is **93.10 GiB**. Prod plus 40 GiB is **133.10 GiB**, requiring the planned increase. |
| Prod temporary quota | Still **4 cores / 96 GiB**. | The requested 7 cores / 144 GiB has not been applied. |
| Legacy moodledata free space | Test approximately **8.7 GiB**; prod approximately **3.7 GiB**. | The return-capacity baseline remains consistent with the runbook. |
| Galera | All three StatefulSets report 5/5 ready. Node 0 in each reports cluster size 5, Primary, Synced, connected and ready. | Stronger evidence than readiness alone; this is not a full five-node consistency or failover test. |
| Moodle maintenance | Test database setting **1**; prod **0**; dev **0**. | Test's captured starting state still matters. Dev remains fenced by its Routes. |
| Legacy automation | `build.yml` **active**; `scheduled-rebuild.yml` **disabled_manually**; health monitors desired at 1 with `MANUAL_MODE=true`. | E4 remains required before coexistence. |
| GitHub sync | Installed-version row still exists in dev, test and prod. | E7 remains preparation work. Its proposed uninstall arguments are supported by the deployed CLI source. |
| Public Routes | Prod has both expected hosts on `web`, target port 8080, with default/180 s timeouts. Test is on `web`; dev's two Routes remain on `maintenance-message`. No alternate backends appeared. | Preserve both prod objects and apply the backend, port and timeout changes together as planned. |
| Existing static fence | Dev's maintenance workload is running; test has no such workload; prod's is at 0 replicas. | Provision and verify the selected fence backend in each target environment. Dev success alone does not make it available in test/prod. This is part of the existing fence deliverable. |
| NetworkPolicy/HPAs | Broad internal and router ingress remains; no legacy HPA appeared. | The runbook's additive-policy warning and fixed-replica assumptions still apply. |
| PoC database | PostgreSQL **15.15**, archive mode on, archive timeout **1 minute**, recent successful archiving. | Useful baseline for C7/C8; no restore was attempted. |

The sibling legacy checkout is on `safety/db-credential-rotation-2026-09-02` and contains local changes. Its `build.yml`
includes a schedule, while the current GitHub default branch uses the separate scheduler described by the runbook.
The GitHub workflow files and enabled states were checked directly; the sibling checkout was not treated as current
remote automation state.

## Disposition of the v0.7 findings

| Previous finding | v0.8 disposition |
|---|---|
| V701 incomplete paired recovery set | **Still open.** Suppressing Moodle's purge addresses the previous immediate-purge timeline, but target coverage is still not established. See V801 and V802. |
| V702 cleanup dependency ordering | **Addressed in design.** Maintenance/drain precedes switching, verification and destruction. Unavailable cleanup defers dependent steps without blocking resumption. |
| V703 duplicate storage across the two trees | **Addressed in design, pending measurement.** Multiple cross-tree link destinations and a lower allowance if sharing fails are appropriate responses. Retain the exact-image and full-rotation tests. |
| V704 backend-based fence invariant | **Addressed in design.** Public Routes pointing to the new stack now satisfy the invariant. |
| V705 contradictory pruning rules | **Addressed in design.** One floor-of-three rule replaces the contradiction. |

## Recommendation

Keep the migration and abandonment architecture. Concentrate the next revision on the backup protocol and the rehearsal
matrix, then implement and run the existing exit gates.

For backups, the smallest proof burden is a coordinated drain and temporary writer fence while establishing a paired
capture and while purging, followed by measured resumption. Whether that brief recurring interruption is acceptable is
an operational decision. If backups must remain fully online, the plan needs a demonstrated protocol for inventory,
pinning, movement, publication and purge; more fixed directory passes are insufficient.

Move the enduring backup/restore utilities out of the directory scheduled for deletion. Keep the existing requirements
for two clean dev rehearsals, measured latest-abort times, a combined restore from independently retrieved artifacts,
and per-environment go/no-go decisions. These are the route to cutover approval once the findings above are closed.
