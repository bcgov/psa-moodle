# Second review: rollback from psa-moodle to moodle-nginx

- **Reviewed:** [replatform-950003-runbook.md](replatform-950003-runbook.md), DRAFT v0.3.
- **Date:** 2026-11-18, America/Vancouver. Live observations were collected on 2026-11-19 UTC.
- **Reviewer:** Codex.
- **Disposition:** Continue preparation; do not approve the test or production cutover yet. The rollback promise still has substantive gaps, including a confirmed production database object that prevents the proposed swap.

The revised runbook makes important improvements: preserving the original database, pinning application code, freezing with CLI maintenance, switching both Routes, and requiring reverse-migration rehearsals. Those are useful foundations. However, preserving tables is only one part of preserving a working recovery path.

My strongest recommendation is to ask for enough temporary **CPU and storage** to keep the legacy serving components available through the bail-out window. Keep legacy cron and interfering automation stopped, and keep legacy in maintenance. Avoid making a Redis cold start part of an emergency return if temporary capacity can remove that dependency. The supplied [platform quota guidance, Example 3](../../platform-developer-docs/src/docs/automation-and-resiliency/request-quota-adjustment-for-openshift-project-set.md) explicitly includes temporary CPU for migrations; approval and the actual amount still need to be established.

The return after reopening must be described as a second migration with its own maintenance window, validation and commit point. It cannot currently be presented as a guaranteed, lossless switch back.

## Scope and limits

I read the revised runbook, the first review, relevant chart/image/backup/CI code, the legacy repository, and the supplied platform documentation. I used authorized **read-only** cluster inspection: resource metadata, selected deployed source files, filesystem capacity, and small SQL metadata/status queries inside read-only transactions. A literal string comparison was also run read-only in MariaDB and the existing dev Postgres proof of concept.

**No cluster resources, application data, maintenance settings, workflows, images or services were changed.** I did not execute Moodle application scripts, perform a migration, exercise a restart, run a restore, or test the public site. The original runbook is unchanged. This separate review is the only repository file added by this review.

No credentials, certificate private keys, encryption keys, learner records or full database dumps are included here. Code inspections and metadata establish the findings; they do not establish that a recovery rehearsal has passed.

Local source revisions inspected:

| Repository | Revision / qualification |
|---|---|
| `psa-moodle` | `1e8bcd251f7223f03026250ce957000ce0f19d71` |
| `platform-developer-docs` | `a82ae4ecea85c1c6ee78bd230e7e6a4bc1431008` |
| `moodle-nginx` | `c167656ada8ff45fbb747da8a8b8f5fb91e02a31`, branch `safety/db-credential-rotation-2026-09-02`; this is not the default branch |

The local legacy checkout differs from GitHub's default-branch workflow files. I separately read [build.yml](https://github.com/bcgov/moodle-nginx/blob/main/.github/workflows/build.yml) and [scheduled-rebuild.yml](https://github.com/bcgov/moodle-nginx/blob/main/.github/workflows/scheduled-rebuild.yml) on GitHub's default branch; they support v0.3's scheduler correction. I did not independently verify the workflows' enabled/disabled state in this pass.

## Findings

“Blocker” means resolve before the affected production-grade step, including rehearsing its replacement. “Major” means a material recovery gap that also needs closure before signing off the rollback promise. These findings supplement R1–R12; they do not treat the already-listed, unfinished C1–C12 changes as newly discovered defects.

| ID | Severity | Section and step | Concrete failure scenario | Suggested change |
|---|---|---|---|---|
| RB01 | **Blocker** | §8.3 swap tooling; §14 step 8 | Production has a trigger on `course_completion_criteria`. MariaDB prohibits moving a triggered table to another database, so the proposed move into `moodle_frozen` fails. Test has no such trigger and would not expose this difference. | Redesign the handover to account for the trigger; preferably evaluate changing legacy's database connection to the verified return database while leaving the original database in place. Rehearse the production schema, trigger and permissions explicitly. |
| RB02 | **Blocker** | §14 steps 9–11; §13.4 steps 3–7 | Cache purge runs before the stopped legacy Redis is restored. Then legacy is opened and cron started before the returned database/site is validated. A failed check can occur after further learner writes or ELM POSTs, making an unswap another data-loss event. | Restore dependencies, purge caches, and validate legacy with learners and background processing fenced out. Make legacy reopening a separate final approval. Define the safe undo boundary before that reopening. |
| RB03 | **Blocker** | §13.4 step 1; §14 failure branches | Rollback starts by invoking PHP maintenance on the failing new stack. If PHP cannot start, Postgres is unavailable, or a rollout is stuck, that prerequisite may be impossible. The bail-out also lacks a documented way to abort the return and resume a still-healthy new site. | Provide an application-independent fencing path and a recovery decision table. Rehearse rollback when new PHP or Postgres is unavailable, and abandoning a failed return without discarding new work. |
| RB04 | **Major** | §11.2; §13.4 steps 3–5; §14 step 10 | Redis and Sentinel are containers in one `statefulset/redis-node`, not separately scalable controllers. Both use `emptyDir`; scaling to zero destroys their state. Redis/Sentinel and legacy PHP/web have no readiness probes in the inspected production definitions. Generic readiness and “scale the new stack to 0” do not establish an operable return or released quota. | Prefer keeping legacy dependencies running. Otherwise specify exact controllers, replicas, cold-start checks, proxy master checks, timeout and fallback. Define controller-aware reduction of the new stack, including Crunchy and any HPA, with measured quota at each state. |
| RB05 | **Major** | §14 step 1 | `pg_stat_database.xact_commit` counts read-only commits too. Monitoring and the verification queries can prevent it becoming constant; statistics cached within one transaction can instead appear falsely constant. “No other client sessions” also fails to distinguish application writers from management/monitoring connections. | Fence writers first, drain requests and transactions, inspect fresh activity with an explicit management-session allowlist, and use write statistics only as supporting evidence. Rehearse the actual query and connection inventory. |
| RB06 | **Major** | §13.1 undo; §13.4 steps 6–7; §4 | Test is intentionally in web maintenance, confirmed live. Unconditional `maintenance.php --disable` restores a different state and opens it to users. `--enableold` alone does not remove the CLI maintenance file. | Capture and restore each environment's original maintenance mode, cron state, replicas and Route state. Rehearse returning test to web maintenance without an interval open to everyone. |
| RB07 | **Major** | §5.4; §14 steps 4 and 6 | The return checks database capacity but not the legacy moodledata destination. Production currently has about **3.68 GiB free** there. New uploads can exceed it during the bail-out window. Returning only `filedir` also omits changes to other durable state such as language customisations and potentially encryption-key files. | Budget and monitor file growth throughout the window; reserve add-only copy and working-space headroom. Inventory durable dataroot state and either freeze it or return it through an explicitly reversible procedure. |
| RB08 | **Major** | S7; §8.4 step 5; §14 step 3; §4 “None” | Matching code does not make database equality rules identical. The live legacy tag index is unique on `(tagcollid, name)` under `utf8mb4_unicode_ci`. Accent variants distinguishable in the current Postgres setup can collide during reverse import. | Add collation/unique-key compatibility cases to rehearsal and a check for reverse-incompatible writes during the window. Decide how to prevent or reconcile them; qualify the unconditional zero-loss claim. |
| RB09 | **Major** | S8; §7 inventory; §9 prerequisites; §12 | A retained Deployment is not a guarantee that a replacement pod can start. Legacy depends on a separate code PVC, mounted configuration and registry images; some images remain mutable tags. A node replacement or scale-up can expose an unavailable image or unrecorded dependency while the deploy pipeline is unusable. | Prepare a private recovery package covering images by digest, code PVC, required configuration/Secrets, volumes and exact manifests. Prove fresh legacy pods can start in dev without the old deploy pipeline. |
| RB10 | **Major** | S12; C8; §13.3; §15 backups | A successful backup Job does not necessarily mean recoverable files or an off-site copy exist. The current snapshot script can exit successfully after skipping a snapshot, and the supplied platform docs support snapshots only on block volumes; moodledata is file storage. Copying to `netapp-file-backup` does not prove its daily OCIO backup has already run. | Require named database/file recovery sets, actual artifact verification, off-site availability evidence and measured restore access. Implement C8 using supported file-backup tooling; do not accept a green Job alone. |
| RB11 | **Major** | §8.2; §13.3; §14 last resort; §15 completion checks | Guarded completion tests can leave real completion state with an intentionally failed ELM POST. The completion task has no replay implementation. Conversely, after opening, returning to the frozen database cannot undo ELM deliveries; legacy can later repeat them. The commit boundary also begins with enabling outbound/cron, before maintenance is removed. | Use isolated synthetic acceptance data with an explicit cleanup/reload decision. Record the first enabled side effect as the commit point. Add ELM reconciliation and duplicate-handling to post-commit recovery and last-resort approval. |
| RB12 | **Major** | S7; C6/C10; §9 E4; CI preparation | E4 freezes legacy automation, but the replacement deploy workflow still runs `upgrade.php --non-interactive` after deployment. When namespace secrets are retargeted to 950003, an automatic deployment can replace the migration image or upgrade the copy and invalidate the reverse path. | Include the new workflow in the freeze/approval design. Replace automatic upgrades in migration mode with a fail-on-mismatch check and pin the reviewed release/image throughout the bail-out window. |
| RB13 | **Major** | §8.3 `bailout-import.sh`; §14 step 5 | Selecting `moodle_bailout` on the client is not protection against SQL containing `USE moodle` or qualified writes to `moodle.*`. A dump made with `--databases` contains database-selection statements. A privileged importer could overwrite the baseline despite the separate-database design. | Specify the dump format, enforce target identity and use an import account restricted to the return database. Test rejection of out-of-scope SQL and record recovery state so retries cannot operate on the wrong database. |
| RB14 | **Minor** | §8.1 egress; §9 Pass A and soak | Removing the current broad HTTPS egress rule also removes the allowance the ops jobs use for the Kubernetes API. Backup/restore checks can fail under the mandated isolated dev profile, encouraging an unsafe broad re-enable. | Separate application internet egress from narrowly scoped ops API access and alert delivery. Prove both isolation and operational checks in that exact dev profile. |

## Evidence and required corrections

### RB01: the proposed atomic swap cannot handle the actual production schema

Read-only metadata inspection found this production trigger:

```text
Trigger: trg_log_completion_criteria_delete
Table:   moodle.course_completion_criteria
Event:   BEFORE DELETE
Action:  insert the deleted criterion into course_completion_criteria_log
```

There was one production trigger, no views, no routines and no events in the inspected schema. Test had no triggers. The log table is explicitly excluded by §5.2 and dropped from the local migration copy by §8.3.

MariaDB documents that a table with triggers cannot move between databases; that operation produces error 1435. Atomicity does not remove this restriction. The multi-table statement should fail, preserving the old names, but it cannot complete the promised handover. [MariaDB RENAME TABLE](https://mariadb.com/docs/server/reference/sql-statements/data-definition/rename-table)

Inventory trigger definitions and dependencies alongside the table inventory. Make a deliberate decision about whether this audit behaviour remains necessary after migration and after returning to legacy. `tool_dbtransfer` creates the target from Moodle's XMLDB schema; do not assume it recreates this custom trigger.

The preferable alternative to evaluate is leaving the frozen `moodle` database in place and pointing legacy PHP/cron and any other consumers at the verified return database. This needs reviewed configuration changes, grants, cache handling and an expanded permitted exception. It is a design recommendation, **not an approved or tested replacement procedure**. If retaining the rename design, trigger removal/recreation and all intermediate failure states need explicit treatment; they are additional writes to the frozen schema.

### RB02–RB06: recovery needs explicit operating states

The current order is: import, copy files, swap, purge caches, restore Routes, run §13.4 steps 3–7, then validate. Section 13.4 includes removing maintenance and starting cron. Move validation ahead of those last two actions, and start the necessary cache services before attempting the purge.

Before legacy reopening, validate the returned database identity, expected records and files, plugin versions, cache health, local login and SSO. Prove an ID can be allocated on the returned database using a controlled synthetic check while public access and business side effects remain fenced. Legacy does not acquire the new image's outbound guard merely because data has been copied back.

Do not require a working new application to stop exposing it. If PHP maintenance cannot run, recovery still needs to stop its ingress and writers through the infrastructure controls already prepared. At the same time, do not treat a Route patch as stopping cron, Jobs, direct service access or an already-running request.

The new stack's controller actions need concrete commands and saved target states. Crunchy documents cluster shutdown through `PostgresCluster.spec.shutdown`; changing an operator-owned StatefulSet alone is not a durable shutdown procedure. Select the operation supported by Silver's installed operator and validate it in dev. Keep the return's source Postgres available until its dump is safely captured. [Crunchy administrative tasks](https://access.crunchydata.com/documentation/postgres-operator/latest/tutorials/cluster-management/administrative-tasks)

Production's inspected cache topology:

| Controller | Replicas | Relevant behaviour |
|---|---:|---|
| `statefulset/redis-node` | 5 | Each pod contains Redis and Sentinel; Redis data and Sentinel state are `emptyDir`; no readiness/liveness probes on either container |
| `deployment/redis-proxy` | 5 | Readiness checks that `ROLE` reports a master; restart needs working Redis/Sentinel discovery |
| `deployment/php` | 3 | No readiness/liveness probe in the inspected definition |
| `deployment/web` | 3 | No readiness/liveness probe in the inspected definition |
| `deployment/cron` | 1 | Also runs the legacy daily moodledata archive loop |

No legacy HPA was returned for test or prod. The new chart can create HPAs, so its recovery values must still specify how they are handled. Do not equate the absence of a legacy HPA with the absence of scaling controllers in the combined namespace.

Postgres documents both the transaction-count meaning of `xact_commit` and the caching/lag of cumulative statistics. Use separate, fresh observations; a statistics counter alone does not fence writers or establish a database/files consistency boundary. [PostgreSQL 15 statistics](https://www.postgresql.org/docs/15/monitoring-stats.html)

The deployed maintenance script also confirms that `--enableold` sets the flag but leaves `climaintenance.html` in place. Returning test to its original web-maintenance state therefore needs a rehearsed transition under an independent access fence. Do not use a brief open interval as the transition mechanism.

### RB07–RB08: the returned data must fit and remain representable

At inspection, production's 12 GiB moodledata filesystem had **3,854,336 KiB available**, about **3.68 GiB**. Each 10 GiB Galera filesystem had about **7.03 GiB available**. These are filesystem measurements, distinct from the **2.90 GiB aggregate unallocated PVC quota**.

The database space check is useful but does not bound file growth, import log/temporary space, or the replication load on the same Galera cluster holding the frozen baseline. Binary logging was enabled, with one-day log expiration. Measure peak import space and load in a representative dev rehearsal; monitor all five Galera volumes throughout the retained window.

A file return should budget the bytes in new content hashes absent from legacy, temporary copy space, and a stated reserve. Alert before that reserve is exhausted. If expanding legacy storage is the remedy, arrange the quota and approval in advance; the current exception list does not authorize arbitrary storage changes during an emergency.

Production's top-level dataroot also includes `lang` and `secret`. Deployed `lib/classes/encryption.php` stores keys under `dataroot/secret/key` unless configured otherwise. I did not read those keys or establish that they currently differ between stacks. The concrete gap is that §14 returns only `filedir`: a language customisation or newly required key created on the new stack is outside that procedure. These files need classification, preservation and a conflict policy. A blanket overwrite of legacy dataroot would defeat the preserved-baseline design.

The collation risk was verified without inserting records:

| Read-only comparison | Result |
|---|---|
| MariaDB 10.6.20: `cafe` equals `café` under `utf8mb4_unicode_ci` | True |
| Existing Postgres 15.15 proof of concept, `en_US.utf-8`: text equality for those values | False |

Production `tag.name` uses that MariaDB collation and has a unique index with `tagcollid`. Deployed Moodle tag code normalises case, but does not remove accents; it looks up names through database equality. Consequently, accepting both tags in one collection on the new site can produce rows the reverse MariaDB unique index rejects. This is a concrete compatibility scenario inferred from the observed schema, comparisons and source; no application write experiment was performed. PostgreSQL explains the byte-distinguishing behaviour of deterministic collations. [PostgreSQL 15 collation support](https://www.postgresql.org/docs/15/collation.html)

Rehearse this case through Moodle in dev, along with fresh users, uploads, course restores, quiz attempts and completion records. The runbook's small new-record test is valuable but does not cover this constraint mismatch. Check the actual 950003 Postgres collation once deployed; the PoC setting is evidence, not a binding specification for the replacement.

### RB09–RB10: preserve a recoverable application and a matching recovery set

Legacy PHP, web and cron mount `moodle-app-data` at `/var/www/html`; the deployed code is not preserved by saving the PHP image alone. They also depend on mounted configuration, `moodle-data`, and shared/cache paths. Production PHP/cron use security-patch image digests, while web and Redis/Sentinel still use tags. Image presence on today's node does not demonstrate that another node can pull and run it.

The platform's [namespace recovery guidance](../../platform-developer-docs/src/docs/automation-and-resiliency/namespace-recovery-and-responsibilities.md) explicitly covers difficult-to-rebuild images, stateful configuration/Secrets, and persistent volumes. The [pruning guidance](../../platform-developer-docs/src/docs/platform-automation/pruning.md) says referenced deployment images are retained; I am **not** claiming the platform will necessarily prune these images during the window. The missing proof is that the complete legacy application can start independently of the broken deploy pipeline.

Preserve an immutable private pre-cutover database/files/code/configuration set. The deployed legacy cron wrapper creates a daily moodledata archive and prunes older archives to keep only the newest. Restarting it must not make that rotating backup the only retained pre-cutover file copy. Preserve the new stack's database **and files**, not just its database, if accepting the last-resort return to old data.

For C8/S12, define an actual recovery-set identifier, database recovery time or backup label, compatible file archive, checksums, retention, encryption/configuration dependencies, and how that set is retrieved. A database restore to a later time than the available file archive can reference missing uploads. A useful rehearsal includes a new upload and a later deletion between backup times, followed by restoration and `check-filedir`.

Current implementation evidence:

- [`moodledata-snapshot.sh`](../scripts/ops/moodledata-snapshot.sh) can exit zero when it cannot find/read the snapshot class, and otherwise submits the snapshot without waiting for readiness.
- [`restore-rehearsal.sh`](../scripts/ops/restore-rehearsal.sh) restores and checks a database; it does not restore moodledata or boot a complete recovered Moodle site.
- [Platform storage guidance](../../platform-developer-docs/src/docs/platform-architecture-reference/platform-storage.md) says only block volumes support snapshots. Current moodledata values use `netapp-file-standard`.
- [Backup-volume recovery guidance](../../platform-developer-docs/src/docs/automation-and-resiliency/netapp-backup-restore.md) describes daily incremental/monthly full OCIO backups, a request-based recovery process, and the source/destination volume information required. A newly written backup PVC is not evidence that a fresh off-site restore point is already available.

C8 already promises new file-backup tooling. Complete that work and make the exit gate inspect usable artifacts, not just Kubernetes Job success. The [platform backup guidance](../../platform-developer-docs/src/docs/database-and-api-management/database-backup-best-practices.md) also requires planning retrieval and recovery when the original database or namespace is unavailable.

### RB11: database rollback does not undo business integrations

Deployed `local/psaelmsync/classes/observer.php` sends the ELM POST and writes a success/error log. The inspected `process_course_completion::execute()` is empty. A deliberately blocked POST must not be treated as a completion that will automatically be replayed later. Section 8.2 says admins must not mark courses complete, while §15 asks for completion checks; reconcile those instructions with named synthetic records and a cleanup or baseline-reload plan.

Record the commit point **before the first action capable of enabling outbound processing**, including a partially completed Helm rollout. Waiting for the subsequent maintenance-disable command to classify the site as committed is too late. A failed activation can already have produced external effects even if no learner logged in.

A successful reverse import preserves the current local logs and task state, which helps continuity. The last-resort frozen return discards those local changes while ELM and mail recipients retain what they received. Define how the operator checks external outcomes, handles uncertain delivery and avoids replaying completions. Reconciliation ownership and acceptable loss need to be explicit before that decision; “recover by hand” is not yet a tested method.

### RB12–RB14: make the safety rules executable

[`deploy.yml`](../.github/workflows/deploy.yml) lines 145–154 unconditionally invoke Moodle's CLI upgrade when the deployment exists. C10's pinned image and S7's no-upgrade rule need corresponding workflow controls. Namespace resolution uses configurable secrets, so the old `a58ce1` wording in comments does not itself prevent a future run targeting 950003.

For the separate-database import, specify a single-database dump format with no database redirection, validate the artifact, and enforce database-scoped write privileges. MariaDB documents that `--databases` adds `CREATE DATABASE` and `USE` statements. Passing a target name to the client does not override a later `USE` in the stream. Rehearse an attempted out-of-scope write being denied in dev, as well as interruption halfway through an otherwise valid import. [MariaDB dump options](https://mariadb.com/docs/server/clients-and-utilities/backup-restore-and-import-clients/mariadb-dump)

The same Galera cluster is still a shared failure domain: separate schemas protect against certain logical errors, not disk exhaustion, cluster instability or resource contention. This is why import capacity, health and baseline backups remain necessary even with restricted credentials.

The current [network-policy template](../chart/psa-moodle/templates/networkpolicy.yaml) documents that its external-HTTPS rule also carries ops access to the Kubernetes API. Preserve narrowly scoped operational access when implementing `externalEgress=off`; do not weaken the copied application's isolation just to make backup tooling work.

Finally, materialise the recovery artifacts before the window. `ops/replatform/` does not yet exist. Add a dedicated conversion runtime with both PostgreSQL and MySQL/MariaDB PHP drivers: the current [PHP Containerfile](../Containerfile.php) installs `pgsql`/`pdo_pgsql`, but not `mysqli`. Record client versions, full Helm values for every state, namespace/cluster assertions, reviewed object lists, exact image digests, Route undo patches and checkpoint evidence. Those are preparation tasks, not commands to invent during an outage.

## What the previous review now resolves, and what remains

| Earlier findings | Assessment of v0.3 |
|---|---|
| R1–R2: outbound and completion observer | Correct direction: guard and cron-off through checks. Still needs implementation and adversarial proof; RB11 sharpens activation and replay semantics. |
| R3: freeze | CLI maintenance is appropriate. The deployed startup code checks the CLI maintenance file before database/session startup, supporting the maintenance-page design. Still prove actual request/task drainage and replace the invalid Postgres counter gate. |
| R4: preserved baseline | Separate import is a substantial improvement. The trigger blocks the chosen handover, and RB13 adds enforcement to the separate-database boundary. |
| R5: exact code | Per-environment pinning fixes the planned Moodle downgrade. RB08 addresses database semantics; RB12 closes the workflow enforcement gap. |
| R6: reverse scaling | More complete prose, but the live Redis topology and controller-specific operations are still missing. |
| R7–R8: hostnames and Routes | Temporary canonical host, response identification and both public Routes are good corrections. Verify certificates/ports and prepare exact undo patches; no newly found contradiction here. |
| R9: automation | v0.3 correctly identifies the default-branch scheduler. Preserve the pause requirement and include replacement automation. |
| R10: backups | Correctly moved before opening. RB10 supplies concrete proof requirements and the off-site timing caveat. |
| R11: SMTP | Explicit application egress change is listed. Still an implementation/rehearsal requirement. |
| R12: content validation | Frozen content hashes and file hashes are much stronger. Add new-write compatibility and representative production return cases. |

One suspected problem was **not** a new finding: the binary-typed source columns do not automatically make `tool_dbtransfer` reject the schema. The deployed `database_exporter.php` explicitly sets `changedcolumns => false` because transfer may repair column types. Extra tables still need the planned handling. Do not alter live legacy column types merely to address that suspicion.

## Rehearsal evidence required before cutover sign-off

Use isolated, authorized dev/local runs. These are requirements for later work; none were performed during this review.

| Scenario | Required evidence |
|---|---|
| Production-specific schema | Include the custom trigger and its dependent audit table in the legacy source fixture; demonstrate the revised handover and its undo. A clean test-schema run is insufficient. |
| Full return at realistic size | Include the full production-scale file set and measured growth allowance. §9 Pass C currently permits a subset; a subset cannot establish the return's storage or transfer time. Include the five-node Galera topology and constrained quota. |
| Every checkpoint return | Exercise CP1, CP2 and CP3 returns with the precise environment-specific maintenance/cron/Route state restored. Record elapsed recovery time. |
| New application unavailable | Recover before commit with PHP down, Postgres unavailable, and a failed Helm rollout. The old-site return must not require new PHP maintenance to succeed. |
| Cold dependency restart, if retained | Start the exact Redis/Sentinel/proxy topology from empty state and freshly pulled images. Verify actual master/quorum and application access, not merely pod readiness. |
| Import failure and wrong target | Interrupt the import, deny out-of-scope SQL, prove the frozen baseline is unchanged, and demonstrate a clean retry or safe abandonment. |
| Failure after database handover | Keep learners/cron fenced, deliberately fail a validation check, then undo the handover and prove the selected site and files remain consistent. |
| Resume new after an aborted bail-out | Restore its public hostname, maintenance state, images, outbound policy and cron without having admitted writes on legacy. |
| Representative new writes | Include uploads, edits/deletes, course restore, quiz attempt, completion/task state, fresh ID allocation, and accent-distinct tags or other unique-key edge cases. |
| Combined recovery | Retrieve an independently retained database/file/configuration set, restore it, boot Moodle and validate files and login. Record recovery time and the latest recoverable point. |
| End of retained window | Recheck image availability, baseline archives, Galera health, file/disk headroom and reverse compatibility before releasing rollback resources. |

For each scenario, record the starting state, expected failures, observed result, maximum permitted wait, next action, and the evidence location. Set a latest-abort time for each production window from the measured rollback duration. Keep a short operator checklist alongside the detailed runbook so a tired person does not need to reconcile sections 11, 13 and 14 during an outage.

## Live facts rechecked in this pass

| Item | Observation |
|---|---|
| Legacy production | Galera 5/5 running; inspected node reported Primary, Synced and ready; MariaDB 10.6.20 |
| Legacy dev | Galera 4/5; remains unsuitable as-is for the required healthy-source rehearsal |
| Core versions | Prod `2024100711.04`; test `2024100711.03` |
| Maintenance flag | Prod `0`; test `1` |
| Aggregate PVC quota used | Dev `68958Mi/96Gi`; test `78948Mi/96Gi`; prod `95332Mi/96Gi` |
| Long-running CPU requests | Dev `1330m/4`; test `1375m/4`; prod `2975m/4` |
| Quota classes | Separate long-running and time-bound compute quotas exist; classify Jobs against the applicable scope rather than adding every request into one CPU pool |
| Production Routes | Both still target `web`, target port `8080`; custom host has a certificate and no timeout annotation; platform host has `180s` |
| Production trigger | One, `trg_log_completion_criteria_delete`; no test trigger returned |
| Production source table count | 719; information-schema data/index estimate about 973.8 MiB, not a fresh exact-row backup validation |
| Production moodledata free | About 3.68 GiB on the 12 GiB filesystem |
| Production Galera filesystems | About 7.03 GiB free on each 10 GiB filesystem |
| Health monitors | Still one replica in prod/test; prod manual mode true, test false; automatic maintenance flags enabled |
| PoC Postgres | 15.15; three 50m/256Mi sidecars per inspected database pod, two on repo host, consistent with the runbook's sidecar warning |
| Network policies | Production broad ingress allowances remain; no new namespace-wide egress allowance selecting all replacement pods was found in that inventory |

These observations do not replace Phase 0 or approval of any future change. They identify the parts of v0.3 that must become precise and demonstrably recoverable before the owner is asked to rely on them.
