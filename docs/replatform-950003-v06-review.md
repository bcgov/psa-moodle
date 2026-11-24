# Fifth review: replatform 950003, DRAFT v0.6

- **Reviewed:** [replatform-950003-runbook.md](replatform-950003-runbook.md), DRAFT v0.6.
- **Date:** 2026-11-24, America/Vancouver.
- **Reviewer:** Codex.
- **Disposition:** Start Phase 1 preparation. I would not approve a test or production cutover from v0.6 as written.

Most previous blockers are addressed in the design. One recovery flaw remains, alongside four narrower backup and
reconciliation gaps. These are corrections to the plan and its required demonstrations. The fact that Phase 1 tooling
has not yet been built is not itself a finding, and this review does not authorize executing any proposed command.

**Owner direction during this review:** the owner considers another person logging in and making changes during review
practically nonexistent, and accepts the remaining reviewer-access risk. That risk is **not a cutover blocker in this
review**. Do not treat the residual V505 restriction issue as an outstanding approval requirement when applying these
findings.

## Scope and evidence

The review covered v0.6, the [v0.5 review](replatform-950003-v05-review.md), the
[v0.4 review](replatform-950003-v04-review.md), earlier findings, relevant source in this repository and
`../moodle-nginx`, and the local platform documentation in `../platform-developer-docs`.

The runbook requests a desk review, but the owner explicitly authorized **read-only `oc` research** during this review.
Inspection included quota, workload, PVC and selected Route metadata; guard-related configuration lines; selected deployed
Moodle source files; and encryption-key file ownership and permissions. No key contents were read.

No cluster resources, application data, maintenance settings, workflows, images or services were changed. No Moodle PHP
scripts, SQL queries, application requests, migrations, restarts or restore drills were executed. Existing unrelated
working-tree changes were preserved. This document, saved at the owner's subsequent request, is the only repository
file added by this review. The runbook and quota draft remain unchanged.

Runbook line references below refer to the reviewed v0.6 and will move when it is revised. Deployed-source references
identify files read from the production PHP pod; they are observations of that deployment, not claims that the same code
exists in this repository.

## Findings

“Blocker” means a procedure can defeat a core recovery promise. “Major” means a material gap to close before signing off
the affected procedure. Neither severity prevents local preparation.

| ID | Severity | Section and step | Concrete failure scenario | Suggested change |
|---|---|---|---|---|
| V601 | **Blocker** | §14, “Abandon and resume,” steps 1–4; §8.3 `legacy-refence.sh` | The return fails because legacy PHP cannot start or Galera becomes unavailable. Abandonment then requires legacy `maintenance.php`, database-switch cleanup, SQL checksums and database deletion before resuming the healthy new stack. Those prerequisites can strand the procedure. | Provide an infrastructure-only legacy fence, then allow the new stack to resume while legacy remains fenced. Defer unavailable SQL cleanup and checksum verification. Rehearse abandonment with legacy PHP down and with Galera unavailable throughout. |
| V602 | **Major** | §8.1 C8; S12 recovery sets | The new scheduled backup explicitly captures the referenced file set, but does not include `secret/` or `lang/`. Restoring that backup onto an empty volume can pass file-hash checks while losing language customisations and the key needed to decrypt stored values. | Include the durable dataroot inventory in every recovery set. Demonstrate restoration onto an empty volume, including a language customisation and decryption of a synthetic encrypted value. |
| V603 | **Major** | C8; §9 Pass C combined restore | Daily file snapshots and database recovery can represent different times. Restoring newer database state can reference uploads absent from the last file snapshot. Conversely, selecting only current references can omit a deleted file required by an earlier database backup. | Specify how each file manifest is paired with an exact database recovery point, retain the required backup/WAL chain, and enforce that target during restore. State the resulting complete-site recovery point objective. |
| V604 | **Major** | C8 snapshot capacity; V508 closure | Hard links save space for unchanged files, but seven retained versions still consume the union of their distinct content. Test's 3 GiB destination can fill while its live file set remains comfortably within its own volume. | Budget retained unique content, the incoming snapshot, interrupted-run leftovers and overhead. Establish the supported churn allowance and resize/escalation procedure. Measure representative replacement activity, not just repeated unchanged backups. |
| V605 | **Major** | §14 abandonment; §14.9 ELM reconciliation | Fencing can interrupt a completion delivery. If the return is abandoned, the procedure resumes the new site without explicitly requiring ELM reconciliation. Restarting cron does not repair an unsent completion: the plugin's completion task has no replay implementation. | Require reconciliation after an abandoned return as well as a successful return, covering completed-but-unsent and received-but-unlogged cases. Add both cases to the mock-endpoint rehearsal. |

## Evidence and closure requirements

### V601: abandoning a return must not depend on the failed return target

This is the principal reason I would withhold cutover approval.

The corrected precommit abort avoids depending on the failing new application. The abandoned-return path needs the
equivalent protection against a failing legacy application. At runbook lines 1222–1229, the sequence requires:

1. `maintenance.php --enable` on legacy;
2. `bailout-unswitch.sh`, if the handover ran;
3. SQL checksums of the original database;
4. deletion of the bailout database and import account;
5. only then, resumption of the new stack.

A failed legacy PHP restart makes step 1 unavailable. Galera becoming unavailable can prevent the maintenance command,
grant cleanup, checksum query and database deletion. Meanwhile, the new stack may be healthy and merely fenced.

The deployed `admin/cli/maintenance.php` loads Moodle configuration at line 28, before processing `--enable`; it is not an
application-independent fence. The upstream
[Moodle maintenance CLI source](https://raw.githubusercontent.com/moodle/moodle/MOODLE_405_STABLE/admin/cli/maintenance.php)
corroborates that ordering.

**Close with:** an abort branch that first proves legacy cannot serve or process work without requiring its PHP or SQL.
Permit the new stack to resume behind that verified protection, with unavailable legacy cleanup explicitly recorded as
pending. Preserve the original database and do not reopen legacy while cleanup remains pending. Rehearse legacy PHP
unavailable and Galera unavailable for the entire abandonment procedure. The existing failure-after-validation rehearsal
should remain as well.

### V602: the file backup needs the durable dataroot state too

C8 at runbook lines 724–734 specifies daily snapshots of the referenced file set. The forward-copy inventory at lines
802–807 separately identifies `lang/` and `secret/` as durable state. Those paths are not part of the referenced
`filedir` hashes and are not explicitly included in C8's backup contract.

Production has a Moodle encryption-key file under `moodledata/secret/key/`; inspection was limited to ownership and
permissions. The deployed `lib/classes/encryption.php` resolves keys under that directory and uses them for decryption.
Recovering database rows and every referenced content hash does not recover that key or language customisations.

**Close with:** an explicit recovery-set manifest covering the database, referenced files, required durable dataroot
items, and configuration dependencies. Restore onto an empty dataroot without borrowing `secret/` or `lang/` from the
running source. Verify a language customisation and decryption of a synthetic encrypted value. Keep caches and other
deliberately excluded transient state out of the backup.

### V603: scheduled database and file recovery points must be paired

The initial frozen cutover set can be consistent. This finding concerns subsequent scheduled backups and their restore
rules.

A concrete failure sequence is:

1. The daily file snapshot completes.
2. A user uploads a file, and the database records its hash.
3. Database backups or WAL capture that newer state.
4. Recovery combines that database state with the earlier file snapshot.

The database restores successfully, but the uploaded file is absent. The reverse ordering also needs handling: a database
backup can reference a file that has been deleted before a later backup enumerates only current references.

PostgreSQL can recover forward through archived WAL, so a database backup label alone does not establish the matching
file state. See [PostgreSQL recovery documentation](https://www.postgresql.org/docs/15/continuous-archiving.html).
The existing [restore-rehearsal script](../scripts/ops/restore-rehearsal.sh), lines 63–67, supplies a source cluster and
repository but no explicit recovery target. It is not yet evidence of a complete-site restore at a paired recovery point.

**Close with:** a defined capture procedure that establishes the database cutoff and its file manifest, plus restore
commands that enforce that cutoff. Retain the required database backup chain and WAL together with the matching files.
State how much work can be lost when only daily complete-site recovery points are available. Extend the already-required
Pass C upload/deletion test to cover both sides of the capture boundary and a restore onto empty storage.

### V604: deduplication improves the budget but does not bound retention space

The new `rsync --link-dest` approach is a substantial improvement over budgeting multiple independent full copies.
However, unchanged files share storage; distinct retained content still occupies space. Rsync also requires the preserved
attributes to match before linking files. See the
[rsync documentation](https://rsync.samba.org/ftp/rsync/rsync.1.html).

An illustrative test workload demonstrates the missing bound:

| Item | GiB |
|---|---:|
| Constant live referenced set | 1.67 |
| Distinct replacement content per day | 0.20 |
| Seven daily replacement increments across seven retained snapshots plus the incoming snapshot | 1.40 |
| Peak distinct content before pruning | **3.07** |
| Proposed test backup destination | **3.00** |

This is **not a measured growth forecast**. It demonstrates that a constant live size does not guarantee the destination
fits the retention policy. Metadata, durable dataroot items and interrupted-run leftovers add to that requirement. An 80%
alert is useful, but does not itself establish that the next backup can complete while preserving the retained sets.

**Close with:** a measured peak-space model for the chosen rotation, an explicit supported churn allowance, and a
documented response when the allowance is approached. Exercise replacement activity and interruption in the rehearsal.
Update the per-environment sizes and aggregate quota calculation if the chosen allowance requires it.

### V605: an abandoned return still needs ELM reconciliation

The deployed source confirms the interruption window:

- `completion/completion_completion.php`, lines 171–176, saves completion state before triggering the completion event.
- `local/psaelmsync/classes/observer.php` sends the HTTP request at line 152 and inserts its local log at line 201.
- `local/psaelmsync/classes/task/process_course_completion.php`, lines 54–56, has an empty `execute()` implementation;
  it does not replay missed deliveries.

The successful-return procedure includes reconciliation, but the abandonment sequence ends by restarting processing and
restoring access. A completion interrupted by the fence can therefore remain unsent, or delivered without a local log,
even though all database work was retained on the resumed new stack.

**Close with:** reconciliation for every post-commit return attempt that fences processing, whether the attempt succeeds
or is abandoned. Preserve the relevant baseline/end-mark evidence and define when unresolved cases are handed to the
owner. In the mock-endpoint rehearsal, abandon after an interrupted request and prove that both an unsent completion and
a received-but-unlogged completion are handled without blind duplicate delivery.

## Disposition of the previous findings

“Addressed in design” means the written remedy is appropriate; it still needs the implementation and demonstrations the
runbook already requires. It does not mean a rehearsal passed during this review.

| Previous item | v0.6 disposition |
|---|---|
| V501: Helm can undo an imperative scale-down | Addressed in design by the persistent fenced values profile and verification after upgrades. |
| V502: SQL-dependent precommit abort | Addressed in design by infrastructure-only fence verification and a separate return-extraction SQL check. |
| V503: GitHub requests despite a blank token | Addressed in design by E7 removal and exclusion from the new image, with pre-E7 copy handling and acceptance checks. |
| V504: abandoning a return exposes the original database | The refence-before-unswitch ordering is corrected. V601 concerns failure of that refencing/cleanup procedure. |
| V505: reviewer restriction timing and identity | Restriction from creation is addressed. Remaining reviewer-access risk is accepted by the owner and is not a blocker in this review. |
| V506: no cron pod exists to inspect | Addressed in design by a controller-template check and a probe with the normal cron entrypoint disabled. |
| V507: production storage arithmetic and Postgres replica choice | Corrected in design: three production instances, no production restore drill during coexistence, and the revised storage budget. |
| V508: file-backup destination capacity | Substantially improved by hard-linked snapshots, but the retention-and-churn bound remains to be established under V604. |

## Live facts rechecked

These are observations from 2026-11-24, not rehearsal results or approval of proposed capacity changes.

| Item | Observation |
|---|---|
| Production aggregate storage allocation | `95332Mi / 96Gi`, unchanged from the earlier review. |
| Production proposed coexistence storage | `95332Mi / 1024 + 40 GiB = 133.09765625 GiB`, leaving `10.90234375 GiB` under the **proposed** 144 GiB limit. The live limit is still 96 GiB. |
| Test aggregate storage allocation | `78948Mi / 96Gi`; adding the proposed 14 GiB gives `91.09765625 GiB`, leaving `4.90234375 GiB`. |
| Long-running CPU requests | Prod `2975m/4`; test `1375m/4`; dev `1430m/4`. |
| Legacy dev Galera StatefulSet | Now reports 5 desired / 5 ready, rather than the earlier 4-node observation. This alone does not prove Galera health or rehearsal readiness. |
| Legacy dev Routes | Still target `maintenance-message`. |
| Production encryption key | A key file exists under `moodledata/secret/key/`; only ownership and permissions were inspected. |

## What would change the recommendation

I would carry these corrections into Phase 1 and the existing dev rehearsals. Before cutover approval, I would require:

1. Abandoning a return with legacy PHP unavailable and with Galera unavailable, while safely resuming the new stack.
2. Restoring a complete, paired recovery set onto fresh storage, including durable dataroot state and enforced database
   recovery boundaries.
3. Demonstrating the chosen backup retention under representative churn and interruption within the resource budget.
4. Reconciling interrupted ELM deliveries after an abandoned return.
5. The two clean Pass B runs and other exit gates already required by the runbook.

The remaining reviewer-access risk does not change this recommendation; the owner has accepted it.
