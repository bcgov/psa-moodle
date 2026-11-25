# Runbook: replatform 950003 from moodle-nginx to psa-moodle

> **Status: DRAFT v0.9 for review, 2026-11-25. Nothing in this runbook has been executed** except Phase 0, which was
> read-only (2026-11-18).
> v0.2 answered the first review ([replatform-950003-review.md](replatform-950003-review.md), R1–R12, §0).
> v0.3 added facts from the 2026-11-18 prod mojibake window (§0.1).
> v0.4 answered the second review ([replatform-950003-rollback-review.md](replatform-950003-rollback-review.md),
> RB01–RB14), added the Phase 0 findings ([replatform-950003-phase0-findings.md](replatform-950003-phase0-findings.md)) and
> recorded the owner's decisions D1–D3 and O1–O4 (§0.2).
> v0.5 answered the third review ([replatform-950003-v04-review.md](replatform-950003-v04-review.md), DR01–DR09, §0.3).
> v0.6 answered the fourth review ([replatform-950003-v05-review.md](replatform-950003-v05-review.md), V501–V508, §0.4).
> v0.7 answered the fifth review ([replatform-950003-v06-review.md](replatform-950003-v06-review.md), V601–V605, §0.5),
> which cleared **Phase 1 preparation to start**.
> v0.8 answered the sixth review ([replatform-950003-v07-review.md](replatform-950003-v07-review.md), V701–V705, §0.6).
> **v0.9 answers the seventh review** ([replatform-950003-v08-review.md](replatform-950003-v08-review.md), V801–V806).
> §0.7 lists every change.
> It supersedes the "request a new project set" direction in `README.md` (Current direction) and
> `docs/quota-request.md`. The plan is to replatform **inside** the existing 950003 namespaces on Silver, using their existing
> quota plus one temporary increase for prod, then release ad4087 (Gold) and retire a58ce1.

---

## How to review this document (reviewers start here)

This is a plan to replace the live Moodle stack in OpenShift project set **950003** (BC Gov Silver).
The service owner is cautious and wants a plan that cannot strand them.

**The core promise (v0.4).**
- **Before the commit point, every step is reversible with zero data loss.** Rolling back never depends on the new stack
  still working (S13).
- **The commit point (S11) is the first action that can produce an external effect.** Until then, no copy of real data has
  been able to email anyone or send anything to ELM.
- **After the commit point, going back is not a switch.** It is a planned reverse migration (§14), with its own window,
  checks, commit point and ELM reconciliation. It is available for a short, fixed window: 3 business days for test, 5 for
  prod. The frozen legacy database is never written, so a failed return cannot strand us.

**Please try to break this promise.**

**If you reviewed v0.8,** check first that each of V801–V806 is resolved by the sections listed in §0.7, and that the
fixes haven't opened new gaps. (Earlier findings: V701–V705 in §0.6, V601–V605 in §0.5, V501–V508 in §0.4, DR01–DR09 in
§0.3, RB01–RB14 in §0.2.)

Look especially for:

1. **Writes to the legacy data.** Any step that writes to the 950003-test or 950003-prod legacy database or moodledata,
   other than the exceptions allowed in §3.
2. **Shared-namespace interference.** Any way the new stack, running beside legacy in the same namespace, could change,
   delete, select or take traffic from a legacy object, or the reverse. Consider name collisions, label selectors,
   NetworkPolicies (including the union with existing namespace-wide policies), Services, Routes, quota exhaustion, and
   legacy automation.
3. **Outbound leaks.** Any way a copy of real data could reach the outside world before the commit point: email, the ELM
   completion POST, ELM/CData reads, the GitHub sync, web services or SSO.
4. **Rollback gaps.** A step without an undo; an undo that is never rehearsed; an undo that depends on the legacy deploy
   pipeline (no deploy has completed since May 2026); an undo that needs the new stack to be healthy; or an undo that does
   not fit in quota.
5. **Quota.** Arithmetic that doesn't add up. Include operator-generated sidecars, rollout surge and backup Jobs, and
   remember that time-bound pods have their own quota (§5.4).
6. **Platform conflicts.** Anything that contradicts the BC Gov platform docs (`../platform-developer-docs/src/docs/`).
7. **Moodle migration pitfalls.** For example `tool_dbtransfer` behaviour, the table-prefix change, MUC configuration, file
   paths stored in the database, plugin versions, wwwroot handling, collation differences, or maintenance-mode semantics.
8. **Stale facts.** Anything in §5 that you think is wrong or out of date.

**How to report.** Use one line per finding:
`ID | severity (blocker / major / minor) | section and step | concrete failure scenario | suggested change`.

**Desk review by default.** Ground truth is this repository, `../moodle-nginx` and `../platform-developer-docs`. Read-only
cluster inspection only with the owner's permission for that review; never change anything. Facts taken from live cluster
inspection are dated in §5.

---

## 0. Changes from v0.1 (first review)

v0.4 replaced two of these v0.2 designs: R4's `RENAME TABLE` swap (now D3) and R6's scaling of legacy Redis (now D1).
§0.2 explains both.

| Finding | What changed | Where |
|---|---|---|
| R1 outbound and cron enabled before CP2 | Cron, email and integrations stay off through CP3. Turning them on **is** the commit point. Every rollback stops the new stack's processing first. | S4, S11, §13.3, §14 |
| R2 ELM observer POSTs directly | Fail-closed guard in `config.openshift.php`: `forced_plugin_settings` replaces every ELM URL and token, plus `noemailever` and web services off. Local copies run on a Podman network with no internet. Rehearsal proves it with a deliberate course completion. GitHub sync is removed from acceptance (unused). | S4, C5, §8.2, §8.4 |
| R3 web maintenance doesn't stop all writers | Freeze uses CLI maintenance (`maintenance.php --enable`), drains running tasks, then proves quiescence before the final dump and file copy. The legacy wrapper (`--wait`) is never used. | §5.10, §13.1 |
| R4 reverse import destroyed the frozen baseline | Reverse import goes into a **separate** database (`moodle_bailout`); the frozen `moodle` database is never written. *(v0.4: the swap is replaced by a configuration switch, D3.)* | S1, §14 |
| R5 build alignment | Each environment's new image is pinned to the exact code its legacy side runs (test `.03`, prod `.04`). Plugins are pinned to identical code. The pipeline never upgrades a copy; it stops on any mismatch. Test is aligned to prod only after both bail-out windows close. | S7, C10, §8.2, §10 |
| R6 reverse scaling and quota | Quota is sized from admitted pod resources, including Crunchy sidecars, rollout surge and backup Jobs. *(v0.4: legacy dependencies are no longer scaled down, D1.)* | §5.4, §11.2, §13.4 |
| R7 wwwroot redirect | CP2 checks run with wwwroot on the temporary host. wwwroot and the Routes switch together afterwards. Every check confirms which stack answered (a response header). | C12, §13.2 |
| R8 two prod Routes | Both prod Routes are switched and undone together. Certificates are preserved; the 900 s timeout is set explicitly; exact undo patches are saved. | §5.7, §13.2 |
| R9 legacy automation touches all Routes | Pausing legacy automation is mandatory before coexistence in any namespace. Restoration conditions are written down. | E4, §5.5, §9 |
| R10 backups before reopening | Working backups and a demonstrated combined restore are required **before** reopening. *(v0.4 tightens this, RB10.)* | S12, §13.3, §15 |
| R11 SMTP egress for backup Jobs only | Chart change C9: SMTP egress for php and cron, present only when outbound is on. | C9, §8.1 |
| R12 row counts are not proof | Per-table content hashes from frozen baselines, with documented expected differences. Files are checked by SHA-1 against their content-hash names. The reverse direction is checked the same way. | §8.3, §8.4, §15 |

## 0.1 Changes in v0.3 (facts from the 2026-11-18 prod mojibake window)

| Fact | What changed | Where |
|---|---|---|
| The weekly legacy deploy comes from `scheduled-rebuild.yml`, not `build.yml`. It was **disabled** on 2026-11-18. | E4 names both workflows | §3 E4, §5.5, §9 |
| **26 columns in prod are binary-typed** where Moodle defines text. Every census and comparison must cover binary types. | Schema check expects them; `compare-content.sh` normalises them | §5.2, §8.3, §8.4, §15 |
| **Prod mojibake is fixed** (80,726 values). There's a new post-fix baseline dump, and three explained exceptions remain. | Phase 1 uses the new baseline | §5.12, §15 |
| Test's mojibake count (51) re-checked over all column types: unchanged | | §5.12 |
| Maintenance behaviour verified live in prod | | §5.10, §13.1 |
| `search_simpledb_index` is derived data | Rebuilt after a copy, never compared | §8.3, §15 |

## 0.2 Changes in v0.4

### Owner decisions (2026-11-23)
| ID | Decision | Where |
|---|---|---|
| **D1** | **One temporary quota request for prod, covering CPU and storage** (platform docs Example 3). Legacy Redis, Sentinel, redis-proxy, php and web **stay running** through the bail-out window, in maintenance with cron at 0. There is no Redis cold start in any rollback or return. Test and dev fit their current quota. | S1 E2, §1, §5.4, §11 |
| **D2** | **Before the commit point: a firm, lossless rollback. After it: going back is a second migration** with its own window, checks, commit point and ELM reconciliation. The bail-out windows are **3 business days for test and 5 for prod**. | Promise, §4, §14, Q9 |
| **D3** | **Return data by loading `moodle_bailout`, then switching legacy `config.php` to it** (legacy php and cron restart). The frozen `moodle` database is never written. No `RENAME TABLE`. | S1 E5, S8, §8.3, §14 |
| **O1** | **Copy only files referenced by the `files` table** (prod 2.93 GiB of 8.4 GiB on disk). Legacy keeps every file until decommission; the unreferenced set is archived privately before decommission and investigated only if someone reports missing content. | §5.3, §8.3, §12 |
| **O2** | ~~GitHub sync's nightly task: leave it in legacy.~~ *Superseded on 2026-11-23 by G1: uninstall the plugin (§0.4).* | §5.9, §8.2 |
| **O3** | **Test's automated course backups: checked read-only on 2026-11-23.** They have failed since 2026-05-20 because the destination directory doesn't exist. Leave the fix to the replatform; the course developers are told (Q21). | §5.12, §10 |
| **O4** | **Drop the prod trigger `trg_log_completion_criteria_delete` on the new stack.** It is not recreated; its log history stays in the archived dumps. | §5.2, §8.3 |

### Second review (RB01–RB14)
| Finding | What changed | Where |
|---|---|---|
| RB01 the prod trigger blocks the `RENAME TABLE` swap | Swap removed. The return switches legacy's database name (D3). The trigger is dropped on the new stack (O4). The prod schema, trigger included, is in the rehearsal fixture. | E5, §8.3, §8.4, §14 |
| RB02 caches purged before Redis restored; legacy reopened before validation | Legacy Redis never stops (D1). The return validates legacy with learners and cron fenced out. Reopening legacy is a separate, final approval, and the undo boundary before it is defined. | §13.4, §14 |
| RB03 rollback needs the failing new application | New rule S13: fence the new stack with infrastructure only (Routes, scale-to-0, `PostgresCluster.spec.shutdown`, a deny NetworkPolicy). There is a recovery decision table. Rehearsals cover new PHP down, Postgres down, a failed rollout, and resuming the new site after an abandoned return. | S13, §13.4, §14, §9 |
| RB04 Redis/Sentinel topology; no probes; "scale to 0" isn't a procedure | Legacy dependencies keep running (D1). The new stack is reduced controller by controller (Deployments, Crunchy shutdown, HPA min = max), with quota measured in each state. | §5.5, §11.2, §13.4 |
| RB05 `xact_commit` is not a write fence | Fence writers first, drain, then inspect `pg_stat_activity` against an explicit allowlist. Counters are supporting evidence only. | §14.1 |
| RB06 unconditional `--disable` changes test's state | New rule S14: record each environment's starting state and restore exactly that. Test goes back to web maintenance behind a Route fence, with no interval open to everyone. | S14, §13.1, §13.4 |
| RB07 legacy moodledata capacity; durable dataroot state | Budget and monitor file growth (prod has 3.68 GiB free on its moodledata volume) with a reserve. `lang/`, `secret/` and other durable dataroot items are inventoried and handled explicitly. | §5.3, §8.3, §14.4 |
| RB08 collation and unique-key incompatibility | The reverse conversion stops on any unique-key conflict, and the owner decides how to reconcile it. Accent-distinct tags are a rehearsal case. The zero-loss claim is qualified. | §4, §8.4, §14.2 |
| RB09 legacy pods may not restart without the pipeline | S8 adds a legacy recovery package (images by digest, code PVC, configuration, manifests), and dev proves that fresh legacy pods start from it. D3 depends on this. | S8, §8.3, §9 |
| RB10 a green Job is not a recovery set | S12 now requires named recovery sets, artifacts verified by reading them, off-site availability evidence and a measured restore. File backups use supported tooling, not snapshots. The snapshot script must fail loudly. | S12, C8, C16, §15 |
| RB11 ELM side effects; where the commit boundary is | The commit point is the first outbound-capable action, recorded before it runs. Acceptance uses synthetic records with a cleanup plan. ELM reconciliation is part of §14 and of the last resort (Q19). | S11, §13.3, §14, §15 |
| RB12 the new deploy workflow runs `upgrade.php` automatically | C13: migration mode has no automatic upgrade and no automatic deploy to 950003; images are pinned. The workflow is part of the E4 freeze. | E4, C13 |
| RB13 the import could escape `moodle_bailout` | Single-database dump with no `USE` or `CREATE DATABASE`, validated before use. Import account with privileges on `moodle_bailout` only. Rehearsal proves out-of-scope SQL is denied. | §8.3, §14.2–14.3 |
| RB14 `externalEgress=off` also cuts ops API access | C15 separates application internet egress from ops jobs' Kubernetes API access. | C15, §8.1 |
| Also: no conversion runtime; `ops/replatform/` doesn't exist | C14: a conversion image with both MariaDB and Postgres drivers. All recovery artifacts exist before any window. | C14, §8.3 |

### Phase 0 facts (2026-11-18, read-only)
The only name collision is `Service php`. The aggregate storage quota is the binding limit, and time-bound pods have
separate quota. There are no legacy HPAs. All web-service tokens belong to the mobile app. The custom webroot scripts are
unused. Legacy alerts go only to Rocket.Chat, which is discontinued. GitHub sync's task runs nightly. Moodle needs `unoconv`
and Ghostscript. There are 19 site admins in prod. Prod's files are 2.93 GiB referenced out of 8.4 GiB on disk. Images go to
the Artifactory repository `m950-learning`. Details are in §5, §6 and the findings document.
Two later facts (2026-11-20): psa-moodle's CI has never deployed or pushed (its secrets aren't set), and a58ce1-dev's Helm
release records are gone.

## 0.3 Changes in v0.5 (third review, 2026-11-23)

The owner accepted all nine findings and both procedure points on 2026-11-23.

| Finding | What changed | Where |
|---|---|---|
| DR01 the application account has no rights on `moodle_bailout` | The handover grants `moodle@%` privileges on `moodle_bailout.*` and proves php can connect with them before anything switches. The undo revokes them. | E5, §8.3, §14.6 |
| DR02 php and cron use separate config files | Both choose their database from the `DB_NAME` environment variable. The handover sets it on **both** Deployments, and on every other consumer in a reviewed inventory, then checks each pod's effective database. | §5.5, §8.3, §14.6 |
| DR03 GitHub sync's manual sync page and file editor bypass the guard | The stored GitHub credential had long since expired (owner, 2026-11-23). Every copy also blanks it. Acceptance proves both paths fail before the commit point. | S4, §5.9, §8.2, §8.3, §8.4, §15 |
| DR04 a deny-all policy can't override existing allows; the fence shut Postgres before the dump | S13 now defines two procedures: a **writer fence**, which keeps the database up for extraction, and a **full shutdown**. Nothing relies on a deny-all policy. | S13, §8.1, §8.3, §13.4, §14.1 |
| DR05 legacy backups keep targeting `moodle` after a return | The handover retargets legacy's database backup to `moodle_bailout`. A verified recovery set of the returned data is required before legacy reopens. | E5, §14.6, §14.8, §15 |
| DR06 the ELM plugin sends before it logs | Reconciliation compares ELM's records with Moodle's completion records as well as the local log, and handles interrupted requests. | §5.9, §8.3, §14.1, §14.9 |
| DR07 backup Jobs count against long-running quota | §5.4 corrected; Pass A measures each pod in the quota class it is actually charged to; the quota draft budgets backup Jobs | §5.4, §9, §11.1 |
| DR08 web maintenance admits all 19 site admins | New rule S15: before the commit point, every Route that reaches a copy is IP-restricted to named reviewers. Acceptance uses synthetic data, and a log check proves nobody else wrote. | S15, §13.2, §15 |
| DR09 SSO can't work through a temporary admin Route | Validation uses the **public** hostnames, IP-restricted (S15), so SSO callbacks stay valid. The admin-check Route is removed. | S15, §8.3, §13.4, §14.7 |
| Distinct state captures | Two immutable named captures, `precutover` and `prereturn`; every restore names the one it uses | S14, §13, §14 |
| Off-site timing | The off-site copy for S12 is the owner's copy on the encrypted laptop disk, made and checksum-verified inside the window (owner decision) | S12, §13.3, §14.8, Q11 |
| Stale facts | Test's health monitor is manual (2026-11-23); legacy test and prod web run `web-security-patch` images by digest; test may stay in web maintenance with no deadline | §5.5, §5.10, §6, §16 |

## 0.4 Changes in v0.6 (fourth review, 2026-11-23)

### Owner decisions on the fourth review
| ID | Decision | Where |
|---|---|---|
| G1 | **Uninstall `local_githubsync`** from legacy test and prod, with Moodle's own CLI, in the same week, before any coexistence starts (new exception E7). The new image is built without it, so the code stays identical on both sides (S7). Until E7 is done in an environment, copies of its data delete the plugin's configuration rows. | S1 E7, S4, §5.9, §8.2, §8.3, §9 |
| G2 | Reviewer boundary: Routes restricted from creation, and in the pre-commit profile `$CFG->siteadmins` is forced to the named reviewers (default: the owner). The owner considers a shared-address bypass very unlikely; this inexpensive control closes it anyway. | S15, §8.1, §8.2 |
| G3 | **Three Postgres instances in prod** (platform guidance). Test runs **two** during its parallel run so that it needs no quota request, and moves to three after legacy test is decommissioned. **No restore drill in prod or test** during the parallel run; restore rehearsals run in dev (C7). Quota draft: **4 → 7 cores, 96 → 144 GiB**. | §5.4, §8.1, §11.1 |
| G4 | **Moodledata backups:** daily `rsync --link-dest` snapshots on `netapp-file-backup`, 7 retained, 10 GiB, alert at 80% | C8, §8.1 |

### Findings
| Finding | What changed | Where |
|---|---|---|
| V501 Helm can undo an imperative scale-down | The writer fence is a **values profile** (`migration.state=fenced`): web, php and cron at 0 replicas, HPAs off, application CronJobs suspended, outbound off. Every upgrade during a fence uses it, and every upgrade is followed by the same verification. The imperative scale-down is only the fallback when Helm or the cluster API misbehaves. | S13, §8.1, §8.3, §13.4, §14.1 |
| V502 the fence's SQL check makes a database-down rollback impossible | Fence verification is **infrastructure-only**, with no SQL. The `pg_stat_activity` check is required **only** before a return's extraction, and failing it stops the return. | S13, §8.3, §13.4, §14.1 |
| V503 a blank token still sends HTTP requests to GitHub | The plugin is removed (G1, E7). Until then, copies delete its configuration rows. Acceptance checks the plugin is absent and that no request reaches GitHub. | S4, §8.2, §8.4, §15 |
| V504 abandoning a return could expose the frozen database | The abandon sequence **re-fences legacy first** (Routes to the static page, CLI maintenance, drain) and only then switches the database back. It verifies that the frozen `moodle` is unchanged. | §8.3, §14 |
| V505 restriction applied late; an IP is not an identity | The chart renders the Route restriction **at creation**, verified before any data is loaded, and site-admin rights are limited to reviewers (G2). A non-reviewer admin from an allowed address must be denied in rehearsal. | S15, §8.1, §13.1, §13.2 |
| V506 no cron pod exists to check | The cron check is a template check plus a **probe pod** built from cron's pod template with its command overridden (`oc debug deploy/cron`); the real cron stays at 0. A consumer with no evidence fails the handover. | §8.3, §14.6 |
| V507 144 GiB was short with the restore drill; 2 vs 3 Postgres instances | G3: three instances, no prod restore drill, and a corrected budget of 133.1 GiB of 144 | §5.4, §11.1 |
| V508 backup destination too small | G4: snapshots store each file once; sized from the real file set with an alert | C8, §8.1 |
| Also | After a successful return, restoring the `precutover` Routes, mode and cron keeps `DB_NAME=moodle_bailout` | §14.8 |

## 0.5 Changes in v0.7 (fifth review, 2026-11-24)

The fifth review's disposition: **start Phase 1 preparation**; cutover approval waits for the V601–V605 demonstrations and
the existing exit gates. The owner accepted all five findings and the decisions below on 2026-11-24. The owner also
accepted the remaining reviewer-access risk (V505); the reviewer agreed it is not a cutover blocker.

### Owner decisions on the fifth review
| ID | Decision | Where |
|---|---|---|
| H1 | **Complete-site recovery point:** if the new stack's moodledata volume is lost, up to **24 hours** of work can be lost (the last nightly paired recovery set). If only the database is lost, recovery is to within minutes (WAL), using the live files. | S12, C8 |
| H2 | **Test's moodledata snapshot destination is 5 GiB** (was 3). Test's new PVCs total 16 GiB, so test runs at about 93.1 of 96 GiB during its parallel run. Prod stays at 10 GiB; the prod quota request is unchanged. | §5.4, C8 |
| H3 | **An abandoned return may leave legacy cleanup pending.** The new site resumes behind an infrastructure-only legacy fence. Until the cleanup and the frozen-database checksums complete, legacy is **not** reopened and is **not** a fallback, including the last resort. | §8.3, §14 |

### Findings
| Finding | What changed | Where |
|---|---|---|
| V601 abandoning a return needs the failed legacy PHP and Galera | Abandonment has two tiers. **Required, infrastructure only:** `legacy-fence-infra.sh` points every legacy Route at the static fence page and confirms legacy cron is at 0; `verify-legacy-fenced.sh` checks it **without PHP or SQL**. The new stack then resumes. **Best effort:** CLI maintenance, the database switch-back, checksums and `DROP DATABASE moodle_bailout`, each recorded as pending if legacy PHP or Galera is unavailable. Rehearsed with legacy PHP down and with Galera unreachable for the whole procedure. | §4, §8.3, §9, §14 |
| V602 the file backup omits `secret/` and `lang/` | Every snapshot and every recovery set includes the durable dataroot items (`secret/`, `lang/`), listed in a recovery-set manifest. Moodle creates a new key silently if `secret/key` is missing, so this is checked by decrypting a canary after a restore onto an empty volume. | S12, C8, §8.3, §9 |
| V603 database and file recovery points aren't paired | *(The T − 60 s pairing below was withdrawn in v0.8; see V701 in §0.6.)* The snapshot's **start time T** is the pairing key. Restores bring the database to **T − 60 s** by point-in-time recovery. Moodle writes a file's content before its database row, and moves deleted content to `trashdir` (restoring it from there on access), so the snapshot copies all of `filedir` and then `trashdir`. pgBackRest retention becomes time-based (at least 8 days), so every retained snapshot has its WAL. The restore script takes an explicit target. | S12, C7, C8, §8.3, §9 |
| V604 retention space isn't bounded | Sizes come from a stated churn allowance (prod about 0.6 GiB a day of replaced content, test about 0.3). The job is space-aware: it builds into `incoming/`, checks free space for the incoming delta before starting, prunes to a floor of 3 verified sets when short, and fails loudly (alerting) rather than starting a set it can't finish. Alert at 70%; the response is to grow the PVC within quota. | §5.4, C8, §9 |
| V605 an abandoned return skips ELM reconciliation | Reconciliation follows **every** return attempt that fenced the new stack after the commit point, successful or abandoned. After an abandonment the window is the fence interval plus a margin. The mock-endpoint rehearsal abandons after an interrupted request. | §8.3, §9, §14.9 |
| Stale facts | Legacy dev Galera reports 5/5 (2026-11-24); its Routes still point at `maintenance-message` | §5.5, Q17 |

## 0.6 Changes in v0.8 (sixth review, 2026-11-24)

The sixth review's disposition: **continue Phase 1**. The owner accepted all five findings on 2026-11-24. They needed no new
owner decisions; H1–H3 stand, and the prod quota draft is unchanged.

| Finding | What changed | Where |
|---|---|---|
| V701 a file deleted and purged just before the copy is in neither directory | *(Superseded in v0.9 by the backup pause; see V801 and V802 in §0.7.)* v0.7's "T − 60 s" pairing is **withdrawn**: Moodle's purge empties the whole trash, whatever its age. The backup job now **owns the trash**. The new stack never purges it (`$CFG->fileslastcleanup`); the job purges only hashes captured in a verified set and unreferenced live. Each run reads the reference **inventory**, then records the WAL position **L** as the database target; copies `trashdir`, `filedir`, then `trashdir` again; and **verifies every inventory hash is in the copy before publishing**. Restores use `--type=lsn`. Dev tests the review's timeline and a purge during the copy. | §5.3, S12, C7, C8, §8.2, §8.3, §9 |
| V702 cleanup steps could run in any order, and Route changes don't drain accepted work | Resumption still doesn't wait for legacy. Cleanup is **strictly ordered**, and each step needs the one before: CLI maintenance and drain; switch every consumer back and prove it; frozen checksums; then revoke the grant and drop `moodle_bailout`. If a step can't run, every later step waits, and **legacy's database configuration is left untouched** meanwhile. | §8.3, §14 |
| V703 a hash moved to `trashdir` is stored again | *(No longer needed in v0.9: sets don't copy `trashdir`.)* Each tree is copied with `--link-dest` to **both** of the previous set's trees (and the incoming set's), which works because Moodle uses the same `ab/cd/<hash>` layout in both. Copies use `-rt`, so only size and modification time decide sharing. Phase 1 proves this with the job image's own rsync, and Pass B measures it. If sharing can't be proven, the daily allowances are **halved** and the volume sizes stay. | C8, §8.4, §9 |
| V704 the fence invariant became false once the public Routes returned to the new stack | The invariant is now by backend: **no Route reaches legacy**. The public Routes point at the fence page during the abandonment, and at the new stack after resumption. | §8.3, §14 |
| V705 contradictory rotation rules | One rule: before a run, prune the oldest verified sets **only down to the floor of 3**, never below; if space is still short, don't start. A set is published only after verification. Alert when fewer than 7 are retained. | C8 |

## 0.7 Changes in v0.9 (seventh review, 2026-11-25)

The seventh review's disposition: **continue Phase 1**. v0.8's live backup protocol could still publish an incomplete set
(V801), and its trash purge could break a live file (V802). The owner accepted all six findings on 2026-11-25, with four
decisions. The prod quota draft's figures are unchanged; its wording was updated.

### Owner decisions on the seventh review
| ID | Decision | Where |
|---|---|---|
| J1 | **Nightly backup pause.** The moodledata backup runs with Moodle's CLI maintenance page up and every writer drained: typically about a minute at 02:30 Pacific, never more than 10 minutes (15 if the job's pod dies; C3). If a limit is reached the site reopens, that night's set is skipped, an alert goes out, and the previous set is kept. Test and prod. | C8 |
| J2 | **The backup job never deletes live files.** Moodle's stock trash cleanup stays on; v0.8's `$CFG->fileslastcleanup` override is withdrawn. | §5.3, C8, §8.2 |
| J3 | **Rehearsal matrix.** Pass B runs on legacy dev's own 4.5.15 code and data with an exact dev build. Pass C runs once per target (test, then prod) on an isolated legacy fixture in dev, built from that environment's recovery package and dump, and returns into it. | §8.2, §9 |
| J4 | **Pair retention.** A nightly set's database half is guaranteed only within pgBackRest's 8-day retention. Alert at 3 days without a new usable set, escalate to the owner at 5; no unbounded database retention. | C8 |

### Findings
| Finding | What changed | Where |
|---|---|---|
| V801 the checked inventory isn't the recovery target's inventory | The live-copy protocol is withdrawn. During the J1 pause no Moodle code runs (verified in `lib/setup.php` and `lib/classes/cron.php`), so the restore point, the inventory and the files describe one state. The job creates a **named restore point**, reads the inventory and copies every new referenced hash before reopening; nothing moves while it copies. The §8.4 negative test now makes the missing hash required at the target. | C8, S12, §8.3, §8.4, §9 |
| V802 a reference query doesn't make purging live trash safe | The job never deletes live files (J2); Moodle's own cleanup owns the trash, with its upstream behaviour. §5.3 now records that `create_file_from_storedfile()` adds a reference without writing content. Sets hold referenced content only, so v0.8's cross-tree storage question (V703) no longer arises and the full daily allowances stand. | §5.3, C8, §8.2 |
| V803 `Forbid` isn't a global lock | One owner per run: a Postgres advisory lock on the job's own session, held throughout and checked before every change. Per-run staging folders, removed by another run only after the Job's deadline has passed. The manifest is staged with the files and published by one rename. Dev tests two runs together and a killed owner. | C8, §8.4, §9 |
| V804 the database half isn't verified before publishing | Publication waits until the repository shows archived WAL through the restore point on the recorded timeline, and a base backup that finished before it. The manifest records the database system identifier, timeline, base backup label, and restore-point name and LSN; `restore-paired.sh` enforces them. Dev rehearses delayed archiving, Postgres down, and a failover between sets. | C6, C8, §8.3, §9 |
| V805 legacy dev runs 4.5.15; test and prod run 4.5.11+ | J3: an explicit matrix of legacy code, source database, conversion runtime and image for every rehearsal. No step returns a database to other code, and legacy dev's database is never downgraded. | §8.2, §9 |
| V806 enduring tooling sat in a directory deleted after Phase 5 | Backup and restore tooling lives in `ops/backup/`, which stays. `ops/replatform/` is deleted only after a restore using the retained tooling alone. | §8.3, §12 |

Also in v0.9:
- live facts the reviewer read on 2026-11-25: dev's free CPU (§5.4), Galera in all three environments, legacy dev's 4.5.15
  (§5.5), and the static fence page's state in each environment (§5.5, §10, §11);
- cron's one-minute cadence is explicit (C3) and checked (§15);
- the fenced profile suspends the backup CronJob (§8.1).

## 1. Summary

| | |
|---|---|
| **What** | Replace moodle-nginx with the psa-moodle Helm chart. **moodle-nginx** is MariaDB Galera ×5, Redis with Sentinel, a Go redis-proxy, a pod-health-monitor, and template/DeploymentConfig deploys driven by GitHub Actions. **psa-moodle** is nginx, PHP-FPM and a cron Deployment, with Valkey and Crunchy Postgres 15 plus pgBackRest. |
| **Where** | The existing namespaces `950003-dev`, `950003-test` and `950003-prod` on Silver. |
| **Why there** | 950003 already has 4 CPU / 32 GiB / 96 GiB per namespace; dev and test fit without any request. The new project set (ad4087 on Gold) cannot run anything without a quota increase. |
| **How** | Install the new stack beside the old one under different names. Data is **copied, never moved**. At cutover, legacy is frozen and both public Routes are repointed. Legacy stays intact, frozen and **running** (in maintenance, cron at 0) for a short bail-out window, and is removed only after sign-off. |
| **Order** | Local → dev → test → prod → decommission. |
| **Platform requests** | **Prod: one temporary request for CPU and storage** (D1), until decommission. Drafted in [quota-request-950003-prod-temporary.md](quota-request-950003-prod-temporary.md): **4 → 7 cores and 96 → 144 GiB**. Test and dev fit today. |
| **Commit point** | The first action that can produce an external effect (S11). Before it, rollback loses nothing. After it, going back is a second migration (§14). |

## 2. Environment roles (`CLAUDE.md` is authoritative)

| Namespace | Users | Treat as |
|---|---|---|
| `950003-prod` | Learners | Production |
| `950003-test` | Course developers and instructional designers, who build courses here | **Production** |
| `950003-dev` | Nobody; ephemeral | The only cluster target for experiments |

## 3. Safety rules

- **S1. Legacy is not modified** until Phase 5, except through these exceptions. Each one is its own approved step with a
  written undo:
  - **E1** Maintenance mode on or off, using the exact commands in §5.10, and always back to the recorded starting state (S14).
  - **E2** Scaling **legacy cron** to 0 at the freeze, and back to its recorded count at a rollback or return. Legacy web,
    php, Redis, Sentinel and redis-proxy **keep running** (D1); scaling them is not part of this plan.
  - **E3** Repointing the public Routes' backend, timeout annotation and target port (§13.2), including pointing them at a
    maintenance page as a fence (S13, S14). Certificates are never changed.
  - **E4** Pausing automation before coexistence in each namespace, with restoration conditions (§9):
    - legacy `build.yml`, plus `scheduled-rebuild.yml` (already disabled on 2026-11-18);
    - the legacy pod-health-monitor, scaled to 0;
    - **psa-moodle's own deploy workflow** (RB12): no automatic deploy or upgrade reaches 950003 during a migration or
      bail-out window.
  - **E5** Return writes, during a return only (§14):
    - create the database `moodle_bailout` and an import account limited to it;
    - load a validated single-database dump into it;
    - add files to legacy moodledata (add-only);
    - restore durable dataroot items per the reviewed inventory;
    - grant the application account `moodle@%` privileges on `moodle_bailout.*` (DR01);
    - set `DB_NAME=moodle_bailout` on legacy php **and** cron (cron stays at 0), and on every other consumer in the
      reviewed inventory; they restart (DR02);
    - retarget legacy's database backup to `moodle_bailout` (DR05);
    - purge legacy caches.

    Undo, from the `prereturn` capture (S14): `DB_NAME=moodle` everywhere it changed, the original backup target, revoke the
    grant, then drop `moodle_bailout`.
  - **E6** Decommissioning (Phase 5).
  - **E7** Uninstalling `local_githubsync` from legacy test and prod (G1, V503). This happens in the same week, in both
    environments, before any coexistence starts. Each environment is its own approved change with the `CLAUDE.md`
    prerequisites: a fresh verified backup, a window, maintenance mode, a go/no-go and the rollback below.
    1. Save the plugin's code directory and its tables and `config_plugins` rows to the private folder.
    2. `php admin/cli/uninstall_plugins.php --plugins=local_githubsync --run` in a legacy php pod. Phase 1 confirms the
       exact 4.5 syntax.
    3. Remove `local/githubsync` from the legacy code volume (`moodle-app-data`), so Moodle doesn't offer to reinstall it.
    4. `php admin/cli/upgrade.php --non-interactive`. **Required:** `uninstall_plugin()` blanks `allversionshash`
       (`lib/adminlib.php`), so until this runs Moodle reports an upgrade pending and **`cron.php` refuses to run**. With
       every version unchanged, it only recomputes the two version hashes, bumps the cache revision counters and sets
       `registrationpending`; no schema, version or `upgrade_log` change (proven on the local prod copy, 2026-11-25).
    5. Verify: `admin/cli/upgrade.php --is-pending` reports nothing pending; cron runs; the plugin is gone from the plugin
       list; the site works.

    Rollback: restore the code directory, then run Moodle's install of that one plugin, and reload its saved rows if wanted.
    Afterwards, prod and test still run identical plugin sets (454).

  **Galera is never restarted, scaled or reconfigured before Phase 5.** A full Galera cold start is the failure mode behind
  the May 2026 eight-hour outage.
- **S2. Legacy data is only read,** except through E5. Database dumps use `mariadb-dump --single-transaction`, and moodledata
  is read through a read-only mount.
- **S3. The new stack is additive and identifiable by name.** Everything it creates is named `psa-moodle-*`: the Helm release
  is `psa-moodle`, and Crunchy objects are `psa-moodle-pg-*`. No literal names, and no selector that can match a legacy pod.
- **S4. Real-data copies stay quiet.** Until the commit point (S11), every copy of real data (local, dev, test or prod) runs
  with:
  - the outbound guard on (§8.2): no email, ELM URLs and tokens replaced with a dead local address, web services off;
  - cron off;
  - for local and dev copies that don't need SSO, no route to the internet at all;
  - **no GitHub sync plugin.** It is uninstalled from legacy (E7) and absent from the new image. Until E7 is done in an
    environment, copies of its data delete the plugin's `local_githubsync_config` rows. Its manual sync page and file editor
    send HTTP requests to GitHub even with a blank or expired token, so blanking the token is not enough (DR03, V503).

  The guard is fail-closed: it is on unless `MOODLE_OUTBOUND=on` is set explicitly.
- **S5. One approved change at a time.** Every cluster change is a numbered step with the exact command, expected result,
  verification and undo, approved by the owner individually. Read-only inspection never needs approval.
- **S6. Test and prod need full preparation:** a fresh verified backup (database **and** moodledata), an agreed window,
  maintenance mode, a go/no-go and a written rollback.
- **S7. Exact code, both directions.** Each environment's new image runs exactly the Moodle core and plugin code its legacy
  side runs (§8.2). No step upgrades a copy, the pipeline stops on any version mismatch, and nothing runs `upgrade.php`
  automatically (C13). **No Moodle upgrade on either side during a bail-out window**, because the reverse migration needs
  identical code.
- **S8. Never rely on redeploying legacy, and prove it can restart.** Legacy CI has failed every deploy since May 2026, so
  rollback relies on legacy *staying deployed*. The return (D3) restarts legacy php and cron, so a private **legacy recovery
  package** exists before coexistence. It holds images by digest, the code PVC's contents, the configuration and Secrets,
  and exact manifests. Dev must prove that fresh legacy pods start from it without the old pipeline (RB09).
- **S9. Personal data stays in owner-only storage.** Dumps, file copies, the recovery package and saved Route YAML (which
  holds certificate keys) go on the encrypted laptop disk, in mode-700 folders with mode-600 files. Never put them in git,
  chat or shared drives.
- **S10. The stop rule.** If anything unexpected happens: stop, return to the last known-good state, write down what
  happened, and only then continue.
- **S11. The commit point is the first action that can produce an external effect.** That is whichever comes first:
  - the `helm upgrade` that sets `outbound=on` or `cron=on`, **even if that rollout fails part-way**;
  - taking the new site out of maintenance.

  It is approved as its own step after CP3 (§13.3) and recorded in the window log **before** it runs, together with the ELM
  baseline (RB11). Before any rollback, the new stack's processing is stopped first (S13).
- **S12. No reopening without a usable recovery set.** Before the new site opens, all of these hold:
  - a **named recovery set** exists, described by a manifest (V602, V603):
    - the database recovery target: a pgBackRest backup label (the window's set), or a nightly set's **named restore
      point**, created during the backup pause, with its timeline and base backup (V801, V804);
    - the file set: the content of every hash in that target's reference inventory, **verified present** (C8);
    - the durable dataroot items: `secret/` (Moodle's encryption key) and `lang/` (language customisations);
    - the configuration it depends on: the chart values file and image digest, and the names of the Secrets it needs;
    - checksums of every artifact;

    Caches, sessions, temp, locks and `muc/` are deliberately excluded.
  - the artifacts are verified by reading them, not by a green Job (RB10);
  - the **off-site copy is the owner's copy on the encrypted laptop disk** (owner decision, 2026-11-23), made and checked
    against the checksums inside the window. `netapp-file-backup` holds a second, in-cluster copy; writing there is not
    proof that OCIO has copied that particular set off-site;
  - scheduled database and moodledata backups run with retention and failure alerts;
  - a combined database-and-files restore from such a set has been demonstrated in dev with the same tooling, **onto empty
    storage**, with the recovery target enforced, and its duration recorded (V602, V603).

  **Complete-site recovery point (H1):** if only the database is lost, it is recovered to within minutes (WAL) and used
  with the live files. If the moodledata volume is lost, the site goes back to the last nightly paired set, losing up to
  24 hours of work. Alternatively, the owner may keep the database current and accept the recent uploads that
  `check-filedir` lists as missing. The owner decides per incident.
- **S13. Fence without the new application.** There are two procedures, both using infrastructure only (DR04):
  - **Writer fence.** It keeps the database up, so a return can still extract from it:
    1. point every Route that reaches the new stack (public, temporary and any restricted review Route) at the fence target
       or at legacy;
    2. `helm upgrade` with the **fenced profile** (`migration.state=fenced`): web, php and cron at 0 replicas, HPAs off,
       application CronJobs suspended, outbound off. The fenced state lives in the rendered release, so a later upgrade
       can't bring writers back. **Every** upgrade while fenced uses this profile (V501).
       - If Helm or the rollout fails, scale and suspend imperatively, then retry the fenced upgrade.
    3. **Verify without SQL** (V502): every application controller desired at 0 with 0 pods; no application Job active;
       every application CronJob suspended; no Route reaches the new application. Repeat after every upgrade.

    Postgres keeps running. A precommit abort needs nothing more, and works with the new database down or unreachable.
  - **Full shutdown**, when database access isn't needed: the writer fence, then `PostgresCluster.spec.shutdown: true`
    (the Crunchy-supported shutdown). It is verified the same way, without SQL.
  - **Database quiescence is a separate check, for returns only:** before extracting data (§14.1), `pg_stat_activity`
    shows only allowlisted management sessions. If the database is unreachable or the check fails, the return stops; the
    abort path above still works.

  NetworkPolicies are additive. A deny-all policy does **not** revoke existing allows (`allow-all-internal`, router ingress,
  the chart's own egress rules), so no step relies on one. `maintenance.php` on the new site is used when it works, but is
  never required (RB03).
- **S14. Restore what was there, by name.** `state-capture.sh` records an environment's state into an immutable, **named**
  capture: maintenance mode, cron replicas, every Route's YAML, the health monitor's state, replica counts, and `DB_NAME` for
  each consumer.
  - `precutover` is taken at the cutover's T0.
  - `prereturn` is taken at the start of a return.

  Every restore step names the capture it uses. Moving legacy from CLI maintenance to web maintenance (as test may need)
  happens **behind a Route fence or restriction**, never through an interval open to everyone (RB06).
- **S15. Before the commit point, only named reviewers reach a copy** (DR08, DR09, V505). Two controls, both in place before
  any real data is exposed:
  - **Network:** every Route that reaches a copy of real data before the commit point carries
    `haproxy.router.openshift.io/ip_whitelist`, set to the named reviewers' addresses. That covers the new stack's temporary
    Route (restricted **from creation**, rendered by the chart, and verified before any data is loaded), the public Routes
    at CP3, and the public Routes while legacy is validated during a return.
  - **Identity** (G2): in the pre-commit profile, `config.php` forces `$CFG->siteadmins` to the named reviewers' accounts.
    Web maintenance therefore admits nobody else, even from an allowed address. The reviewers are named before each window;
    by default it is the owner alone.
  - Checks that need SSO use the **public hostnames**, so the registered callbacks work.
  - Rehearsal proves that a non-reviewer admin, from an allowed address, is refused.
  - Acceptance uses synthetic records only. Before the commit point, a log check shows no writes by anyone outside the
    reviewer list.
  - The restriction is lifted only as part of the commit point (§13.3) or legacy's reopening (§14.8).
  - Dev Pass B proves that the router honours the annotation.

## 4. Can we always get back to moodle-nginx?

| Stage | What users reach | Roll back by | Data lost | Rehearsed in |
|---|---|---|---|---|
| Phase 0–1 (local only) | Legacy | Nothing to undo | None | n/a |
| Legacy automation paused (E4) | Legacy | Re-enable the workflow; scale the monitor to 1 | None | Dev 2.0 |
| New stack installed beside legacy | Legacy | `helm uninstall psa-moodle`, then delete its listed PVCs and kept Secrets | None | Dev Pass A |
| Legacy frozen (CP1) | Legacy, in CLI maintenance | §13.4, ending in the recorded state (S14) | None | Dev Pass B |
| New site checked on temporary host (CP2) | Legacy, in CLI maintenance | Writer fence or full shutdown of the new stack (S13); then as CP1 | None | Dev Pass B, including new PHP down and Postgres down |
| Routes switched, new site in maintenance (CP3) | New, admins only | Routes back with saved patches; then as CP2 | None | Dev Pass B |
| **Commit point**: new site open (bail-out window) | New | **Second migration** (§14): its own window, checks and commit point | Normally none, but **not guaranteed**: unique-key conflicts (RB08) and ELM deliveries need reconciliation | Dev Pass B, including a failed import, out-of-scope SQL, a failed validation and an abandoned return |
| Return abandoned before legacy reopens | New, resumed | §14 "Abandon and resume": an infrastructure-only legacy fence, then resume; legacy cleanup may stay pending (H3) | None; ELM reconciled for the fence interval (V605) | Dev Pass B, with legacy PHP down and with Galera unreachable throughout |
| Last resort | Legacy, on the frozen database | Point legacy at the frozen `moodle`, only after any pending cleanup and the frozen checksums pass (H3) | Everything since reopening; ELM reconciled | Dev Pass B |
| After decommission | New | Restore from backups only | n/a | n/a |

During a bail-out window, legacy stays frozen and **running**. Galera is untouched. Redis, Sentinel, redis-proxy, php and web
run (D1). Legacy cron is at 0, and the site is in CLI maintenance.

## 5. Known facts (re-verify the live ones at the start of each phase)

### 5.1 Versions and plugins (live, 2026-11-17 and 2026-11-18)
- **Prod** is Moodle `4.5.11+ (Build: 20260525)`, version `2024100711.04`. **Test** is Build 20260519, version `2024100711.03`.
  Both have `backup_version` `2024100700`. Both run MariaDB 10.6.20.
- All 455 plugin versions are identical in prod and test.
- **Exact code, copied 2026-11-25** (read-only, checksums matched against the pods) to the private folder
  `legacy-code-20261125/`. Prod's core is `MOODLE_405_STABLE` at `32d78752`, test's at `d94b3c54`; dev (4.5.15) has no
  `.git`. Prod and test differ in 71 files (34 in `mod/hvp`, the rest in add-ons, core `version.php` and Composer
  files). All three environments run the same php image; the code lives on each `moodle-app-data` volume.
- The psa-moodle image is built from the **head** of `MOODLE_405_STABLE` and of each plugin's branch
  (`Containerfile.php`, `git clone --depth=1 --branch`), so its exact code is not pinned. It **lacks `report_allbackups`**
  (6 add-ons against prod's 7).
- Prod's PHP and cron were hand-patched on 2026-10-21 with `*-security-patch` images. The psa-moodle image has PHP 8.3.36.
- psa-moodle's web image uses nginx **1.30.7** (`docker.io/nginx/nginx-unprivileged`, pinned by digest, 2026-11-20). The
  November 2026 nginx advisories are fixed in it.

### 5.2 Database (live, 2026-11-17 and 2026-11-18)
- **Prod:** 719 tables (all InnoDB) and 5,250,571 rows. The dump is about 96–100 MB gzipped (710 MB of SQL). On disk: 486 MiB
  data, 488 MiB index, 189 MiB free.
- **Test:** 713 tables and 316,427 rows; the dump is 10.1 MB gzipped. On disk: 55 MiB data, 50 MiB index.
- **Table prefix:** legacy uses `$CFG->prefix = ''`. psa-moodle's `config/moodle/config.openshift.php` uses `'mdl_'`.
- **Tables that are not in Moodle's schema** make `tool_dbtransfer` abort. Its `migrate.php` calls
  `database_mover(..., check_schema=true)`, which rejects extra tables.
  - Both environments: **195 `bht_*` Behat tables.**
  - Prod only: `course_completion_criteria_log` and six `local_psaelmsync_logs_*` copies:
    `_backup`, `_backup_20240522`, `_backup2`, `_bad_restore`, `_copy2` and `_muckedup`.
  - Test only: `local_psaelmsync_enrol`.
- **One custom trigger, prod only:** `trg_log_completion_criteria_delete` (`BEFORE DELETE` on `course_completion_criteria`,
  inserting into `course_completion_criteria_log`). It was created on 2026-05-15, during the split-brain recovery. There are
  no views, routines or events. Two consequences:
  - MariaDB cannot move a table that has a trigger to another database (error 1435), which is why the swap is gone (RB01).
  - **The new stack drops it (O4):** `tool_dbtransfer` builds the target from XMLDB, and the trigger is not recreated.
- `tool_dbtransfer` rebuilds `log_display` in the target, so that table is an expected difference (§8.3).
- **Binary-typed columns (prod, found 2026-11-18).** 26 columns are `longblob` or `varbinary` where Moodle's XMLDB defines
  text or char, most likely left over from the 2025 encoding conversion:
  - content: `page.content`, `book_chapters.content`, `forum_posts.message`, `event.description`,
    `hvp_xapi_results.description`, `question_attempts.questionsummary`, `.responsesummary`, `.rightanswer`;
  - short fields: `course.format`, `qtype_multichoice_options.answernumbering`, `quiz_attempts.state`, `user.auth`,
    `user.calendartype`, `user.lang`, `user.timezone`, `wiki.defaultformat`, `wiki.firstpagetitle`, `wiki.name`,
    `wiki.wikimode`;
  - `sha256hash` in `local_psaelmsync_logs` and its six ad-hoc copies.

  Consequences:
  - `check_database_schema.php` reports them.
  - They compare byte-wise and case-sensitively in MariaDB.
  - Any census or content comparison must include binary types; the 2026-11-17 census did not, and missed 76,644 mojibake
    values.
  - `tool_dbtransfer` does not reject them: its exporter sets `changedcolumns => false`.
  - After the 2026-11-18 fix every value in them is valid UTF-8.
  - **Test does not have this drift:** its only binary-typed columns are ASCII `sha256hash` fields.
  - Converting them back to text in legacy is **not** part of this plan.
- **Three more leftover tables, all empty in prod** (found 2026-11-25): `name`, `tool_lockstats_history` and
  `tool_lockstats_locks`. `tool_dbtransfer` skips them (they aren't in XMLDB), so they're expected differences.
- **First local forward conversions (2026-11-25, laptop, `ops/replatform/local-pipeline.sh`):**

  | | Load | Forward (to Postgres) | Reverse (to `moodle_bailout`) | Tables | Rows | `compare-content`, both directions |
  |---|---:|---:|---:|---:|---:|---|
  | Prod (post-fix dump, 18 Nov) | 92 s | **607 s** | **425 s** | 511 | 5,146,273 | every value identical except `log_display` (rebuilt) |
  | Test (17 Nov dump) | 10 s | 59 s | 76 s | 511 | 310,029 | the same |

  So the full round trip, MariaDB to Postgres and back, changes no data. Both have the same three empty leftover tables,
  which are not converted. Test needed no NULL filling. Still to come in §8.4: new writes before the reverse (accent-
  distinct tags, RB08), booting each stack against the result, and the timings on the cluster.
- **Nullable drift (found 2026-11-25 on a local copy of the post-fix prod dump).** `check_database_schema.php` also
  reports **72 columns that Moodle's XMLDB defines as NOT NULL but are nullable in prod** (29 tables, including `user`,
  `course`, `question` and `forum_posts`), and four default or length differences in `local_psaelmsync_logs`. No row
  holds a NULL in any of the 72. **The binary-typed columns hide the same drift** (the check reports only their type):
  `user.timezone` has **4,036 NULLs** and `course.format` **1** (course 231), and the first conversion attempt stopped on
  it. The pipeline therefore fills such NULLs with Moodle's own XMLDB default, in the local copy only, and lists each
  change as an expected difference: `user.timezone` → `99` (use the site timezone, which Moodle already does for an empty
  value) and `course.format` → `topics` (the site default format, which Moodle already falls back to). A NOT NULL column
  with NULLs and no default stops the pipeline for a decision. The target is built from XMLDB, so Postgres enforces NOT
  NULL again, and a return restores the constraint in `moodle_bailout` too.
- **Collation differs** (RB08). Legacy uses `utf8mb4_unicode_ci`, where `cafe` equals `café`. The PoC's Postgres 15
  (`en_US.utf-8`, deterministic) treats them as different. Prod's `tag` table has a unique index on `(tagcollid, name)`. So
  accent-distinct values accepted by the new site can collide in a reverse conversion. The 950003 Postgres collation is
  checked at Pass A.
- **Verified backups** are in `~/Moodle/private-backups/`: prod's final post-fix baseline (2026-11-18T23:36Z) and test's
  (2026-11-17T23:10Z).

### 5.3 moodledata (live, 2026-11-18)
| | Prod | Test |
|---|---|---|
| PVC | `moodle-data`, 12 GiB RWX, `netapp-file-standard` | same |
| Used / free | 8.4 GiB / **3.68 GiB** | 3.4 GiB / 8.7 GiB |
| `filedir` on disk | 9,326 files, 8.4 GiB | 7,342 files, 3.4 GiB |
| Referenced by `files` | 8,772 hashes, **2.93 GiB** | 7,241 hashes, **1.67 GiB** |
| On disk but unreferenced | 557 files, 5.25 GiB | 110 files, 1.56 GiB |
| Referenced but missing | 3 (one badge's images, 2021) | 9 (2021 user icons and backups; 2 H5P files, 2026-01) |

- **O1: only referenced files are copied** to the new stack. Legacy keeps every file until decommission.
- The unreferenced prod files are mostly 10–100 MiB. Their modification dates cluster in 2025-06 and 2026-05 (the two
  database events), but file dates reflect copies and restores, so their origin can't be told from metadata.
- **Durable dataroot items besides `filedir`** (RB07):
  - `lang/` (language customisations);
  - `secret/` (Moodle's encryption key lives in `secret/key` unless configured elsewhere). On the 18 November prod copy,
    no configuration value is encrypted with it, and the MFA secrets and OAuth 2 system-account tables are empty, so
    today little depends on the key; it is still carried over, and the canary (§8.3) proves it works;
  - `antivirus_quarantine/` and `.quarantine-20260826T190745Z/`;
  - `muc/config.php`, Moodle's cache-store configuration. It points at the **legacy Redis** and is never copied.

  §8.3 says how each item is handled.
- In legacy, `cachedir` and `tempdir` live under `/var/shared`, and `filecache` and `localrequestdir` on a RAM disk.
- `filedir` is content-addressed: each file's name is the SHA-1 of its content. It is append-only in normal operation.
- **Deleted content** (Moodle 4.5, `lib/filestorage/file_system_filedir.php` and `file_storage.php`):
  - when no `files` row references a hash any more, `remove_file()` moves it to `trashdir`, at the same `ab/cd/<hash>`
    path it had under `filedir`;
  - `recover_file()` moves it back automatically if a record that references it is read;
  - adding content from a file or a string checks **only** `filedir`: if the hash isn't there, Moodle writes a fresh copy
    (through a `.tmp` file), and never takes it from `trashdir`. Content is written before its `files` row is inserted;
  - **copying a file record writes no content** (V802): `create_file_from_storedfile()` (`file_storage.php`, line 1095)
    inserts a new `files` row for an existing hash. A request that read the source row before another request deleted the
    last reference therefore re-references a hash that is already in `trashdir`, or already purged;
  - `\core\task\file_trash_cleanup_task` runs every 6 hours. Once `$CFG->fileslastcleanup` is more than a day old, it
    removes files of deleted contexts and then **empties the whole trash, whatever the age of each file** (V701). Setting
    `$CFG->fileslastcleanup = time();` in `config.php` turns that block off. The new stack keeps the stock behaviour (J2).

  So no copy of the live directories can be proven to match a database target. C8 captures while writers are drained
  instead (J1).
- Legacy cron also writes a daily `moodledata` `.tar.gz` to `/tmp/file-backups/moodledata` and **keeps only the newest**. It
  is not a retained pre-cutover copy (RB09).

### 5.4 Quota and capacity (live, 2026-11-18)
Figures are **requests against quota**, not utilization. Long-running compute:

| Namespace | CPU free | Memory free | Storage free (aggregate) |
|---|---|---|---|
| Dev | 2.570 of 4 (2026-11-25) | 28.40 of 32 GiB | **28.66** of 96 GiB |
| Test | 2.625 of 4 | 26.53 of 32 GiB | **18.90** of 96 GiB |
| Prod | **1.025** of 4 | 26.53 of 32 GiB | **2.90** of 96 GiB |
| Tools | 2.000 of 2 | 8.00 of 8 GiB | 18.00 of 64 GiB |

- **The binding storage limit is the aggregate `storage-quota`.** Each storage class also has its own quota (for example
  96 GiB of `netapp-block-standard`, unused), but the aggregate caps them all. Legacy uses only `netapp-file-standard` and
  `netapp-file-backup`.
- **Time-bound quota** (`compute-time-bound-quota`, 4 CPU / 32 GiB per namespace, unused) applies only to pods with a
  **pod-level** `activeDeadlineSeconds`. The PoC's pgBackRest backup CronJobs set none, and nor do the chart's integrity and
  restore-rehearsal templates. Their pods therefore count against **long-running** quota (DR07), and are budgeted there
  unless the admitted pods actually qualify. The moodledata backup Job (C8) does set one, so it is time-bound; the prod
  quota draft still counts it as long-running, to be safe.
- Of prod's 2.975 CPU used, Redis, Sentinel and the proxy request 1.75. With D1 they keep running, so the new stack needs
  temporary CPU on top.
- **Admitted resources are more than the chart's containers.** The a58ce1 PoC admits **0.900 CPU / 2.69 GiB** at single
  replicas:

  | Pod | CPU | Memory | Containers |
  |---|---|---|---|
  | Postgres instance | 0.400 | 1.25 GiB | 4 |
  | pgBackRest repo host | 0.100 | 512 MiB | 2 |
  | php | 0.200 | 512 MiB | 1 |
  | cron | 0.100 | 256 MiB | 1 |
  | valkey | 0.050 | 128 MiB | 1 |
  | web | 0.050 | 64 MiB | 1 |

  Rollout surge also counts. Sizing uses admitted requests from dev Pass A, not template sums.
- **D1 request,** drafted in [quota-request-950003-prod-temporary.md](quota-request-950003-prod-temporary.md): prod
  **4 → 7 cores and 96 → 144 GiB**, from the start of prod coexistence until decommission.
  - CPU covers the new stack's peak, about 2.8 cores: three Postgres instances, rollout surge, backup Jobs counted as
    long-running, and the return's configuration probe (V506). With legacy's 2.975 that is about 5.8 of 7.
  - Storage covers 40 GiB of new PVCs: moodledata 6, Postgres 3 × 5, the pgBackRest repository 8, the moodledata
    snapshot destination 10 (G4) and Valkey 1. With legacy's 93.1 GiB that is **133.1 of 144 GiB**.
  - **No restore drill runs in prod during the parallel run** (G3, C7); combined restores are proven in dev (S12).
  - Replace these planning numbers with Pass A's admitted requests if they exist when it is submitted.

  **Test needs no request** if it runs **two** Postgres instances during the parallel run (three would need about 2.8 CPU
  against test's 2.6 free). The test profile is about 2.15 CPU, and **16 GiB** of PVCs: moodledata 3, Postgres 2 × 2,
  repository 3, snapshot destination **5** (H2, V604) and Valkey 1, against 18.9 GiB free. That is about **93.1 of 96 GiB**
  (re-checked on 2026-11-24: 78,948 MiB allocated), leaving 2.9 GiB. Nothing in a test return creates a PVC. It has no
  restore drill. Test moves to three instances after legacy test is decommissioned. Pass A confirms these numbers.
- **Legacy Galera PVCs:** prod 5 × 10 GiB with about 7.0 GiB free each; test 5 × 7 GiB with 5.1 GiB free each. Both are
  more than twice the database size, which a return needs (§14.0).

### 5.5 Legacy machinery that can interfere
- **`build.yml` is the only legacy workflow that deploys.** Its triggers are pushes and pull requests to `950003-dev`,
  `950003-test` or `950003-prod` (including dependabot PRs to `950003-dev`), and manual dispatch. **It has no schedule.** The
  weekly run came from `scheduled-rebuild.yml`, which dispatches `build.yml` on `950003-dev`. **`scheduled-rebuild.yml` was
  disabled on 2026-11-18** (undo `gh workflow enable`). E4 disables `build.yml`.
- **Cleanup deletes by fixed name.** `cleanup.yml` deletes the Service, Deployment, ConfigMap, PVC, Route and Secret by
  name. A new object whose name matches a legacy name could be deleted.
- **Legacy maintenance scripts patch every Route in the namespace** (`openshift/scripts/utils/maintenance-mode.sh` lines
  98–100, `remove-maintenance-message.sh`). They are never used during the migration.
- **The pod-health-monitor.** In all three namespaces: `GALERA_AUTO_HEAL_ENABLE_FAILSAFE=true`, `FAILSAFE_SCALE_REPLICAS=0`,
  and automatic Moodle and OpenShift maintenance. `MANUAL_MODE=true` in all three namespaces; test was switched on 2026-11-23 (Q18).
  **Its only alert channel is `ROCKET_CHAT_WEBHOOK`. Rocket.Chat is discontinued, so nobody receives its alerts.**
- **Prod cache topology** (RB04):

  | Controller | Replicas | Notes |
  |---|---|---|
  | `statefulset/redis-node` | 5 | Each pod has `redis` and `sentinel` containers; data and Sentinel state on `emptyDir`; no readiness or liveness probes |
  | `deployment/redis-proxy` | 5 | Readiness checks the master `ROLE` |
  | `deployment/php` | 3 | No probes |
  | `deployment/web` | 3 | No probes |
  | `deployment/cron` | 1 | Also runs the daily moodledata archive loop |

  **There are no HPAs** in any legacy namespace. With D1 none of these is stopped during the migration.
- **Legacy images (2026-11-23):** php, cron and, in test and prod, web run `*-security-patch` images by digest.
  - Web was rebuilt for the November 2026 nginx advisories in the moodle-nginx work. On 2026-11-18 it was still a mutable
    `nginxinc/nginx-unprivileged:1-alpine-slim` tag.
  - redis-proxy comes from Artifactory, by digest.
- **How legacy finds its database (DR01, DR02, DR05):**
  - php mounts ConfigMap `moodle-config`, and cron mounts `cron-config`, each as `/var/www/html/config.php` via `subPath`.
  - Both set `$CFG->dbname = $_SERVER['DB_NAME'];`, so each Deployment's `DB_NAME` environment variable chooses the database.
  - The application account `moodle@%` has privileges on `moodle.*` only.
  - Legacy's database backup (`moodle-db-backup-storage-config`) targets `mariadb-galera:3306/moodle`.
  - Cron's CLI-maintenance gate is the shared `climaintenance.html` (`lib/classes/cron.php` checks `CLI_MAINTENANCE`).
    Removing that file reopens cron, whichever database cron points at.

  The code is on the `moodle-app-data` PVC, mounted at `/var/www/html`. An environment-variable change restarts the pod,
  and a `subPath` ConfigMap change needs a restart, which is why S8 matters.
- **Legacy dev is not yet a proven rehearsal source.** Galera was at 4 of 5 nodes on 2026-11-18. On 2026-11-25 the reviewer
  read all three environments' Galera StatefulSets at 5 of 5 ready, with node 0 reporting cluster size 5, Primary and
  Synced; that is not a full consistency or failover test. Both of dev's Routes still point at `maintenance-message`.
  Legacy dev runs **4.5.15** (`2024100715`), newer than test and prod (J3). Pass B needs a healthy legacy dev (Q17).
- **Static fence page (reviewer, 2026-11-25).** Dev's `maintenance-message` workload is running; test has none; prod's is at
  0 replicas. Each environment's fence target is provisioned and verified before its window (§10, §11).
- **Course flow automation.** `migrate-courses-between-namespaces.sh` moves courses between namespaces by running `oc exec`
  in the legacy pods. It breaks after the replatform (Q5).

### 5.6 Chart, image and pipeline changes required before deploying into 950003
| # | Finding | Why it matters |
|---|---|---|
| C1 | `templates/php-service.yaml` creates a Service with the literal name **`php`**. **The only collision found by Phase 0**, in dev, test and prod. | Collides with legacy `service/php` |
| C2 | `templates/job-install.yaml` runs `install_database.php` on every `helm install` | A migrated site needs an empty database for `tool_dbtransfer` |
| C3 | `templates/cron-deployment.yaml` always runs one replica | S4 and S11 need cron off until the commit point |
| C4 | `psa-moodle-allow-monitoring` uses `podSelector: {}` (confirmed in Phase 0) | It opens ports 9187 and 9253 on **legacy** pods |
| C5 | No outbound guard | S4 needs the fail-closed guard in §8.2 |
| C6 | Values, images and hostnames point at a58ce1 | a58ce1 is being retired |
| C7 | `backup.restoreRehearsal` creates a temporary Postgres cluster. `scripts/ops/restore-rehearsal.sh` (lines 63–67) names a source cluster and repository but **no recovery target** | Needs storage headroom; a restore without a target isn't paired with any file set (V603) |
| C8 | The pgBackRest repository is on `netapp-block-standard`; retention is a count of full backups (`repo1-retention-full: 7`, `count`); there is no moodledata backup suitable for file storage | S12 needs an off-site copy, verifiable file backups and WAL covering every retained file snapshot; `netapp-file-standard` does not support snapshots |
| C9 | The SMTP egress policy selects only the backup components | Moodle's own email would be blocked after reopening |
| C10 | Moodle core and plugins are cloned from branch heads | S7 needs exact, per-environment code |
| C11 | Only the chart's own Route has the 900 s timeout | The public Routes keep 180 s or the 30 s default unless the cutover sets it |
| C12 | Nothing identifies which stack served a response | CP2 and CP3 checks must prove the new stack answered |
| C13 | `deploy.yml` runs `upgrade.php --non-interactive` after every deploy (line 154); the namespace comes from secrets | It could upgrade a copy or replace a pinned image (S7, RB12) |
| C14 | `Containerfile.php` has `pgsql`/`pdo_pgsql` but no `mysqli` | The conversion runtime needs both drivers, in both directions |
| C15 | The chart's external-HTTPS egress rule also carries ops jobs' Kubernetes API access | `externalEgress=off` would break backup checks (RB14) |
| C16 | `scripts/ops/moodledata-snapshot.sh` exits 0 when no snapshot class exists, and doesn't wait for readiness | A failing backup looks green (RB10) |

**psa-moodle CI today:** `build.yml` only verifies builds, because `ARTIFACTORY_PASSWORD` is unset. `deploy.yml` always skips,
because the `OPENSHIFT_*` secrets are unset. The image home is `artifacts.developer.gov.bc.ca/m950-learning` (Q13). Setting up
those secrets is a Phase 1 task, and only after C13 is in place.

### 5.7 Routes and hostnames (live, 2026-11-18)
| Namespace | Route | Host | To | TLS | Certificate | Timeout |
|---|---|---|---|---|---|---|
| prod | `moodle-custom` | `learning.gww.gov.bc.ca` | `web` | edge, HTTP→HTTPS redirect | **custom** | default (30 s) |
| prod | `moodle-web` | `moodle-950003-prod.apps.silver.devops.gov.bc.ca` | `web` | edge | router | 180 s |
| test | `moodle-web` | `moodle-950003-test.apps.silver.devops.gov.bc.ca` | `web` | edge | router | 180 s |
| dev | `moodle-web` | `moodle-950003-dev.apps.silver.devops.gov.bc.ca` | `maintenance-message` | edge | router | 180 s |
| dev | `redis-insight` | `redis-insight-950003-dev.apps.silver.devops.gov.bc.ca` | `maintenance-message` | none | n/a | default |

All legacy Routes use `targetPort: 8080`. The new chart's Service port is named `http`; its Route uses `targetPort: http` and
`timeout: 900s`. Full Route YAML is saved privately (S9).

### 5.8 NetworkPolicies (live, 2026-11-18)
- The platform applies a default deny in every namespace; allow policies are **additive**.
- `allow-all-internal` selects all pods and admits the same namespace and tools; **test's also admits 950003-dev**. Router
  ingress and console policies select all pods.
- Legacy's database and cache policies admit broad sources. The details are in the owner's private Phase 0 notes. Copy Jobs
  can reach Galera without new policies.
- No legacy policy restricts egress for Moodle pods.
- So the new stack's pods are reachable from those namespaces whatever the chart's own policies say. The plan does not
  claim per-component isolation; database and Valkey rely on their authentication. Phase 5 reviews the broad policies.

### 5.9 Integrations and outbound traffic
- **ELM completions (writes to ELM).** `local_psaelmsync`'s observer for `\core\event\course_completed` POSTs straight to
  `completion_apiurl` with `completion_apitoken`, using `curl_init`. Its "completion" scheduled task has an empty `execute()`
  and **no replay**. So any completion on a copy would report to the real ELM, and a blocked POST is never re-sent (R2, RB11).
  The POST (`curl_exec`, line 152) happens **before** the log insert (line 201). A process stopped between the two leaves a
  delivery with no local log entry, so the log alone is not a complete record of deliveries (DR06).
- **`local_psaelmsync` settings** (the guard's override list): `apiurl`, `completion_apiurl` (prod
  `analytics-api.psa.gov.bc.ca`, test `analytics-testapi.psa.gov.bc.ca`), `apitoken`, `completion_apitoken`, `enabled`,
  `notificationemails`, `notificationhours`, `datefilterminutes`, `ignorecourseids`, `last_record_enrol_id` and `version`.
  Test also has `dashboardlink`.
- **`local_githubsync` is unused** (owner), but:
  - its `sync_courses` task is enabled and runs nightly in prod and test;
  - each environment has one `local_githubsync_config` row (`auto_sync = 0`) holding a stored GitHub credential;
  - its manual sync page (`sync.php`) and its AJAX file editor call `https://api.github.com` directly with that credential,
    bypassing plugin settings and the web-services switch (DR03).

  The credential had long since expired (owner, 2026-11-23), but a blank or expired token **still sends the request**: a GET
  from manual sync, and a PUT carrying the edited content from the file editor (V503). **G1:** the plugin is uninstalled from
  legacy test and prod (E7) and left out of the new image. Until then, copies delete its configuration rows. This supersedes
  O2.
- **SMTP:** `smtphosts = apps.smtp.gov.bc.ca`; `allowedemaildomains = *.gov.bc.ca`.
- **SSO:** core `oauth2` only. "BC Government Login" is enabled (prod `loginproxy.gov.bc.ca`, test
  `test.loginproxy.gov.bc.ca`). Prod also has a disabled "Azure AD Login" issuer.
- **Web services:** enabled (`rest`). **All 25 prod tokens belong to the Moodle mobile app** (last used 2026-11-04, 23
  expired); test has 5, last used in 2024. There are no other database accounts. Q6 is answered: nothing else integrates.
- **Custom webroot files** (`cdata-proxy.php`, `list_courses.php`, the tag scripts, `migrate-courses`, `fix-mojibake*`,
  `moodle_index_during_maintenance.php`, `redis-stats.php`): **no requests in two weeks of prod logs** (Q8). They are not
  carried over.

### 5.10 Maintenance modes (deployed `admin/cli/maintenance.php`, verified 2026-11-18)
| Command | Mode | Who gets in | Cron |
|---|---|---|---|
| `php admin/cli/maintenance.php --enable` | **CLI maintenance.** Writes `climaintenance.html` and sets `maintenance_enabled = 'cli mode'` | Nobody over the web | Suspended |
| `php admin/cli/maintenance.php --enableold` | **Web maintenance** (`maintenance_enabled = 1`); leaves any `climaintenance.html` in place | Admins (19 in prod, 14 in test), and web-service callers with maintenance access | **Not** suspended |
| `php admin/cli/maintenance.php --disable` | Off (`maintenance_enabled = 0`, file removed) | Everyone | Normal |

- **Use:** CLI maintenance to freeze a source (legacy at cutover, the new stack at a return). Web maintenance on the new site
  between CP1 and reopening, with cron off and the outbound guard on, so admins can check it.
- Going from CLI to web maintenance needs `--disable` then `--enableold`, which opens the site for about a second. **S14:**
  fence the Routes first, so the interval is never exposed.
- The legacy wrapper `config/moodle/enable-maintenance-mode.sh` passes an invalid `--wait`. It is never used.
- A copy taken during CLI maintenance carries `maintenance_enabled = 'cli mode'`, so it should start in web maintenance even
  without `climaintenance.html`. Rehearsal confirms this.
- **Observed in prod on 2026-11-18:**
  - `--enable` returned 503 on both hostnames at once.
  - A cron keep-alive loop already running finished about a minute later; then cron logged "CLI maintenance mode active, cron
    execution suspended", and `wsrep_last_committed` stayed constant.
  - The CLI page shows `$CFG->maintenance_message`, which now reads "We're running some upgrades, back soon!".
  - CLI scripts other than cron run normally.
- **Test has been in web maintenance since 2026-11-17,** and the owner is content for it to stay there with no deadline. Its
  window records whatever state it is in at T0, in the `precutover` capture (S14).

### 5.11 Legacy `config.php` and environment settings that psa-moodle does not set
- `disablelogintoken = true`
- `xsendfile = 'X-Accel-Redirect'`, with aliases
- `debugsessionlock = 10`
- `langstringcache`, `cachejs` and `enablecssoptimiser`
- `session_redis_serializer_use_igbinary = true`
- `wwwroot` derived from the request's `HTTP_HOST`
- **`pathtounoconv = /usr/bin/unoconv`** and **`pathtogs = /usr/bin/gs`**: the new image must include both, or document
  conversion and PDF annotation break.

Each one needs a decision, recorded in §16.

### 5.12 Data quality
- **Prod mojibake: fixed on 2026-11-18.** 80,726 values were repaired (4,082 in text columns and 76,644 in binary-typed
  columns), and the search index was rebuilt.
  - Acceptance (text and binary columns, plus a stray-character check): zero mojibake outside the excluded tables, except
    three explained values: `hvp_libraries_languages` id 863 "Âm" (Vietnamese); `book_chapters` id 961 and its search
    document (one invisible U+009D); and 8 orphaned search documents that Moodle deletes when a search touches them.
  - **Phase 1 uses the final post-fix baseline** `950003-prod-moodle-postfix2-20261118T233645Z.sql.gz`, or a newer frozen
    dump at cutover.
- **Test mojibake:** 51 known values plus one U+FFFD, all in courses that will not be used. The owner decided **not to fix**
  them. Re-checked over all column types: unchanged. Test's copy of the Vietnamese "Âm" is id 2289.
- **Test's automated course backups have failed since 2026-05-20 (O3).**
  - Each run logs "Specified backup directory is not writable – /tmp/file-backups/courses" (784 errors since 2026-11-01).
  - The configured directory doesn't exist on the `file-backup-data` volume, and the last automated backup file is from
    2026-05-20.
  - `backup_courses.laststatus` shows "OK" for most courses, so the log, not the status, is the reliable signal.
  - Course developers' work is covered by the nightly database backup and the daily moodledata archive (newest only).
  - The replatform's backups replace this; see Q21.

### 5.13 Traffic by hour (owner's query, read-only, 2026-11-25)
Moodle's event log (`logstore_standard_log`, web and web-service events by real users), hourly, Pacific time:
- **Prod, 1 October to 24 November 2026 (39 weekdays, 16 weekend days):** 92.2% of weekday events fall between 07:00
  and 16:00, and 5.9% between 16:00 and 17:00. After 17:00 there is **1.5%**, and **no weekday hour after 17:00 had more
  than 4 distinct users**; from 18:00 it was at most 2. Weekends total 1.7% of events, at most 2 users in any hour. The
  busiest hour (10:00) reached 227 distinct users.
- **Test, the 8 weeks before its maintenance began on 18 November:** 251 events in total, at most 2 users in any hour,
  and one person, once (two events), after 17:00.
- The prod web pods' access logs for 23–25 November agree.

This is the basis for K2: windows start at 17:00, and a maintenance page outside business hours goes essentially unseen.

## 6. Open questions for the owner

| ID | Question | Why it matters | Default if unanswered |
|---|---|---|---|
| Q1 | Who owns `learning.gww.gov.bc.ca` (DNS and certificate renewal)? *Test's only hostname is `moodle-950003-test.apps.silver.devops.gov.bc.ca` (Phase 0).* | Certificates must survive the Route switch | Patch the existing Route objects in place; never delete or recreate them |
| Q2 | Who can change the "BC Government Login" redirect URIs? Does anything need `disablelogintoken`? | Login must work the minute the Routes move | Keep the same hostnames; keep `disablelogintoken` until we know |
| Q3 | Is the ELM endpoint IP-allowlisted? Can ELM tell us about duplicates or test traffic? | Outbound safety, and the first post-reopening check | Treat any POST from a copy as an incident |
| Q4 | *Answered: GitHub sync is unused. G1: it is uninstalled from legacy test and prod (E7) and is not in the new image* | | |
| Q5 | Do course developers use the tag-based migration script, or move `.mbz` files by hand? | The script breaks after the replatform | Assume manual; tell the developers |
| Q6 | *Answered by Phase 0: only Moodle mobile app tokens; no other database accounts* | | |
| Q7 | Who must be told about downtime? Is there a change-approval process? | Comms and approvals | The owner decides each time |
| Q8 | *Answered by Phase 0: the custom webroot scripts are unused; not carried over* | | |
| Q9 | *Answered (D2): bail-out windows are 3 business days for test and 5 for prod; the owner makes each go/no-go call* | | |
| Q10 | Do the `bht_*` and ad-hoc `local_psaelmsync_logs_*` tables, and the trigger's log table, need keeping beyond the archived dumps? | They are not migrated | The archived dumps are enough |
| Q11 | *Answered 2026-11-23: the off-site copy is the owner's copy on the encrypted laptop disk, made and verified inside each window. `netapp-file-backup` holds a second, in-cluster copy* | | |
| Q12 | Who approves the GitHub changes (disabling `build.yml`; environment protection)? | E4 | The owner. Default branch is `main` |
| Q13 | *Answered by Phase 0: `artifacts.developer.gov.bc.ca/m950-learning`* | | |
| Q14 | Who receives alerts, and who is on call? *Legacy's alerts go only to the discontinued Rocket.Chat.* | Monitoring; S12 failure alerts | The owner, by email, until a channel is chosen |
| Q15 | Are there events to avoid when choosing windows (cohort starts, deadlines)? | Choosing windows | Ask before each window |
| Q16 | Is copying production personal data to the owner's encrypted laptop acceptable under PSA policy for the migration pipeline? | §13 uses a local pipeline | It was done on 2026-08-26, 2026-11-17 and 2026-11-18; confirm |
| Q17 | Legacy dev is unproven (Galera 4/5 on 2026-11-18; 5/5, Primary and Synced, on 2026-11-25; Routes on the maintenance page; runs 4.5.15). Check and repair it in dev? | Pass B needs a healthy legacy source; S8 needs a restart proof | Repair legacy dev as its own approved dev-only step, after E4 |
| Q18 | *Done 2026-11-23 (owner approved): test's health monitor is `MANUAL_MODE=true`. Undo: `oc -n 950003-test set env deploy/pod-health-monitor MANUAL_MODE=false`* | | |
| Q19 | *Answered 2026-11-23: the owner is the ELM contact for reconciliation (§14.9) and for the first post-opening check* | | |
| Q20 | *Answered 2026-11-23: site-level administration is frozen during bail-out windows (settings, language strings, plugin configuration); admins are told before each window* | | |
| Q21 | *Answered 2026-11-23: the course developers have been told that test's automated course backups haven't run since May* | | |

## 7. Phase 0: read-only discovery — **done 2026-11-18**

All steps ran read-only on 2026-11-18. The results are in
[replatform-950003-phase0-findings.md](replatform-950003-phase0-findings.md) and summarised in §5 and §16. Security
observations are in the owner's private notes. **At the start of each environment's phase, re-run steps 0.2, 0.5, 0.8, 0.11
and 0.13** for that environment.

| Step | What | How (all read-only) |
|---|---|---|
| 0.1 | Log in; one context per namespace | `oc login`; `oc --context … whoami` |
| 0.2 | Inventory | quota, workloads, Services, Routes, PVCs, NetworkPolicies, ConfigMaps, Secret names, RBAC, Helm release secrets; image streams in tools |
| 0.3 | Name collisions | `helm template` (dev and test values), list kind/name, intersect with live objects (normalise whitespace) |
| 0.4 | NetworkPolicies | The union per namespace; confirm no chart policy selects a legacy pod |
| 0.5 | Quota arithmetic | Per class and aggregate, long-running vs time-bound, against admitted requests |
| 0.6 | Crunchy | `oc api-resources --api-group=postgres-operator.crunchydata.com` |
| 0.7 | Image home | Artifactory objects in tools; pull secrets; legacy image references |
| 0.8 | Legacy automation | Health-monitor settings and alert channel; cron; HPAs; GitHub workflows |
| 0.9 | Moodle settings (SQL) | Auth, OAuth2 issuers, plugin setting names, `local_*` tasks, tokens by service, admins, database accounts, `pathto*`, automated backups, repositories, mail, search, column types, **triggers** |
| 0.10 | Custom script usage | php-pod access logs (the nginx `web` pods log nothing) |
| 0.11 | Data sizes | `information_schema`; moodledata `df` and `du`; referenced vs on-disk files; Galera PVC free space |
| 0.12 | Maintenance serving | `maintenance-message` per namespace |
| 0.13 | Routes | Host, target, port, TLS, certificate, annotations; full YAML saved privately |
| 0.14 | Record | Findings document; §5, §6, §16 |

## 8. Phase 1: local preparation (no cluster changes)

Work on a branch (`replatform-950003`) and have changes reviewed. Nothing here touches OpenShift, except pushing images,
which happens as its own approved step.

### 8.1 Chart and pipeline changes
- **C1:** render nginx's FastCGI upstream from the release's own php Service (for example a ConfigMap carrying
  `fastcgi_pass <fullname>-php:9000`), and delete the literal `php` Service.
- **C2:** add `install.enabled` (default `true`). Migrated installs set it to `false`. *Done 2026-11-25:* it gates the
  installer Job and sets `MOODLE_INSTALL_ENABLED` (which turns on `nokeygeneration`).
- **C3:** add `cron.enabled`, so cron runs 0 or 1 replicas. Every 950003 values file keeps `cron.mode: deployment` with
  `intervalSeconds: 60`. Moodle expects a cron run every minute, and on Silver Kyverno throttles a CronJob that mounts a PVC
  to hourly (recorded in `cron-deployment.yaml` from the PoC), so cron is a one-pod loop, never a CronJob. The loop doesn't
  start `cron.php` while the backup's `climaintenance.html` is present, and removes a backup-marked one older than
  15 minutes (C8). It never touches an operator's maintenance file.
- **C4:** scope every NetworkPolicy to release selector labels; no `podSelector: {}` anywhere.
- **C5:** add `moodle.outbound: off | on` (default `off`), which sets `MOODLE_OUTBOUND` for php and cron (§8.2). *Done
  2026-11-25,* with `moodle.reviewerAdmins` (`MOODLE_REVIEWER_ADMINS`, G2). The existing PoC values files set `on`, so
  those sites keep today's behaviour.
- **C6:** add `values-950003-{dev,test,prod}.yaml` with:
  - temporary hostnames;
  - the image home and the per-environment image digest (C10);
  - sizes that fit the Phase 0 numbers, with `maxSurge` set so a rollout fits;
  - Postgres instances: **3 in prod, 2 in test during its parallel run** (G3);
  - the temporary Route's `route.allowedSources` (reviewer addresses). It is rendered as
    `haproxy.router.openshift.io/ip_whitelist`, and **defaults to admitting nobody**, so the Route is restricted from
    creation (S15, V505);
  - **HPAs set to min = max** (or disabled) in every migration state (RB04);
  - `restoreRehearsal` off until storage headroom is confirmed (C7). When used, the restore always takes an explicit
    target: a nightly set's restore point with its base backup and timeline
    (`--type=name --target=<set id> --set=<label> --target-timeline=<timeline>`), or `--set=<label> --type=immediate` for
    the window's set (V603, V804);
  - alert recipients (Q14).
- **C8, C16:** backups that S12 can rely on (RB10):
  - pgBackRest on `netapp-file-backup`, with the final recovery set also copied to the owner's encrypted disk as the
    off-site copy (Q11).
    - **Retention is time-based** (`repo1-retention-full-type: time`, at least **8 days**), so each nightly set's restore
      point stays reachable for 8 days (J4). A weekly full, daily differential and hourly incremental schedule
      keeps the repository small; Pass A measures its peak use against the PVC (prod 8 GiB, test 3 GiB).
  - a moodledata backup suited to **file** storage (G4, V508, V602–V604): each night, a set of the content the database
    references, on a `netapp-file-backup` PVC, 7 retained, taken during a short **backup pause** (J1).
    - **Why a pause (V801, V802).** Moodle moves content between `filedir` and `trashdir`, and copying a file record adds
      a reference to a hash without writing its content (§5.3). So no copy of the live directories can be proven to match a
      database target. During the pause no Moodle code runs: a web request checks for `climaintenance.html` before it opens
      a database connection (`lib/setup.php`), and the cron loop doesn't start `cron.php` (C3). The restore point, the
      reference inventory and the files then describe one state. The probes don't run Moodle (`php-fpm-healthcheck`, nginx
      `/health`), so pods stay ready and visitors see the maintenance page.
    - **The job never deletes live files (J2).** Moodle's stock trash cleanup stays on. Sets hold referenced content only;
      `trashdir` is not backed up.
    - **Access:** the job mounts moodledata read-write but writes only its own `climaintenance.html`; everything else it
      only reads. It connects to Postgres as its own role, which can read `mdl_files` and run `pg_create_restore_point()`
      (granted in the chart's database initialisation SQL). It reads pgBackRest's repository information through
      `pods/exec`, limited by `resourceNames` to the repository host's pod.
    - **Each run:**
      1. **Lock (V803).** Take a Postgres advisory lock on the job's own session and hold it to the end; if it is already
         held, exit. Before every later change, confirm the session still holds it. If the session is lost, stop; the only
         thing the run still does is remove its own maintenance file (step 7). If a `climaintenance.html` already exists,
         an operator's or another run's, skip the run without pausing.
      2. **Space:** the rotation check below, before pausing.
      3. **Pause and drain.** Write `climaintenance.html`, marked with the run id, atomically (a temporary name, then a
         rename). Wait until **no session of Moodle's database role** has existed for 10 consecutive seconds. Moodle keeps
         no persistent connections (`dbpersist => false`) and there is no pooler, so a session means Moodle code is running.
         Scheduled Jobs that connect as Moodle's role are scheduled outside the pause. Limit: 5 minutes.
      4. **Target (V804).** `SELECT pg_create_restore_point('<set id>')`; record its LSN and timeline. No Moodle
         transaction commits between the end of the drain and the reopening, so the target's boundary is unambiguous.
      5. **Inventory (V801).** Read the distinct `contenthash` of every non-directory `mdl_files` row. Nothing has changed
         since the restore point, so this is the target's own inventory.
      6. **Capture.** For each inventory hash not in the previous published set, copy its content from `filedir`, or from
         `trashdir` if it is there, into this run's staging folder (`incoming/<run id>/filedir/ab/cd/<hash>`), and check
         that its SHA-1 equals its name. A hash in neither tree is a **source gap**: the live site lacks it, not the
         backup. Then copy `secret/` and `lang/`. Limit: 5 minutes.
      7. **Reopen.** Remove the job's `climaintenance.html`. A shell `trap` does this on any exit, including termination at
         the Job's deadline. If the pod dies outright, the cron loop removes a backup-marked file older than 15 minutes (C3).
      8. **Complete and check coverage** (site open). Hard-link every other inventory hash from the previous set. Every
         inventory hash must be present with the right size, apart from recorded source gaps; otherwise the set is not
         published. A source gap not listed in `expected-differences.md` alerts as a live-site incident; the set is still
         published, because it matches the site exactly.
      9. **Database gate (V804).** Wait, up to 30 minutes, until the repository (`pgbackrest info --output=json`) shows a
         backup of the same database system and timeline that finished before the restore point, and archived WAL through
         the restore point's segment. Otherwise: don't publish, keep the previous set, alert.
      10. **Publish.** Write the manifest into the staging folder, then rename the folder to `sets/<set id>/` in one step.
          The manifest records the set id; the database system identifier, timeline, restore-point name and LSN, and base
          backup label; the inventory's count and checksum; the source gaps; the durable items' checksums; and the pause's
          timings. Set files are read-only, because consecutive sets share them.

      If a limit in step 3 or 6 is reached, the job reopens the site, skips the night, alerts, and keeps the previous set.
      The window's recovery set (S12) is written to the same volume as `sets/<window id>/`, so the first nightly run
      hard-links from it and no run copies the whole file store during a pause.
    - **Staging is per run (V803).** A run never touches another run's staging folder, except to remove one older than the
      Job's `activeDeadlineSeconds` plus a margin, whose pod can no longer be running. `concurrencyPolicy: Forbid` stays as
      a second control.
    - **Schedule:** nightly at 02:30 Pacific (J1). The Job has a pod-level `activeDeadlineSeconds`, so it counts against
      time-bound quota (§5.4). The S11 upgrade enables the CronJob, and the fenced profile suspends it. Uptime alerts
      tolerate a pause of up to 10 minutes. A daily CronJob that mounts a PVC is within Silver's Kyverno limit (C3).
    - **Restore** of a nightly set: the database to its restore point
      (`--type=name --target=<set id> --set=<label> --target-timeline=<timeline>`), then the set's files into `filedir`,
      and the durable items (`restore-paired.sh`, §8.3).
    - **Retention and pairing (J4).** A set is a usable pair while the repository still holds its base backup and the WAL to
      its restore point. Each run re-checks the retained sets and marks any whose database half has expired as files-only.
      The newest usable pair is never pruned. pgBackRest keeps 8 days, so a usable pair survives 8 days without a new one;
      alert at 3 days without a new usable pair, and escalate to the owner at 5.
    - **Rotation (V604, V705).** Before pausing, the job estimates the delta from `mdl_files` (the sizes of referenced hashes
      not in the previous set) and needs that much free space plus 10% of the volume. If space is short, it deletes the
      oldest sets, files-only ones first, **only down to the floor of 3**, never below, and alerts. If space is still short,
      it **does not start**, alerts, and leaves the retained sets intact.
    - **Sizes and supported churn (H2):** prod 10 GiB, test 5 GiB. Allowing 25% growth of the live set and 10% overhead,
      that supports about **0.6 GiB a day** (prod) and **0.3 GiB a day** (test) of deleted or replaced content across 8
      sets (7 retained plus the incoming one). A hash is stored once and hard-linked from set to set, and `trashdir` isn't
      copied, so v0.8's cross-tree question (V703) no longer arises.
    - **Alert at 70%,** and whenever retention falls below 7. The response: grow the PVC (every NetApp class can grow, within
      the namespace's storage quota), or the owner approves a shorter retention. Phase 1 estimates upload volume from the
      prod and test dumps (busiest 8-day window) and revises the sizes if that exceeds the allowance.
  - `moodledata-snapshot.sh` fails loudly, or is removed for file-class volumes;
  - every backup Job ends by verifying its artifact.
- **C9:** an SMTP egress policy for php and cron to `apps.smtp.gov.bc.ca`, rendered only when `moodle.outbound=on`.
- **C11:** the public Routes' timeout is set by the cutover patch (§13.2), and by the chart from Phase 5.
- **C12:** nginx adds `X-PSA-Stack: psa-moodle` (and the release name) to every response.
- **C13 (RB12):** in `deploy.yml`, migration mode has:
  - no automatic deploy to any 950003 namespace;
  - no `upgrade.php`; instead, a version check that fails on any mismatch with the pinned build;
  - images referenced by digest;
  - a required-reviewer GitHub environment per namespace.

  The OpenShift and Artifactory secrets are added only after this is merged.
- **C15 (RB14):** separate the application's internet egress (`networkPolicy.externalEgress`) from a narrowly scoped rule
  for ops jobs' Kubernetes API access and alert delivery. Prove both in the isolated dev profile.
- **Fenced profile (S13, V501):** `migration.state: normal | fenced`. `fenced` renders web, php and cron at 0 replicas,
  HPAs off, application CronJobs with `suspend: true` (the moodledata backup included), and outbound off. Every upgrade
  during a fence uses it. `verify-fenced.sh` also checks that no backup Job is active and no backup-marked
  `climaintenance.html` remains.
- **Fencing (S13, DR04):** no deny-all NetworkPolicy, because policies are additive. The writer fence and the full shutdown
  are scripted in `ops/replatform/` (§8.3). Any policy meant for the database pods must select Crunchy's own labels: the
  operator's pods don't carry the Helm release selector.
- **Route:** the chart's Route only ever carries the temporary hostname. **The public Routes stay legacy objects** until
  Phase 5.
- **Validation:** `helm lint`, `helm template` and `ops/replatform/check-collisions.sh` (read-only; normalises whitespace).

### 8.2 Image changes
- **Exact code (C10, S7).** Build one image per legacy build: **test** at `2024100711.03` (Build 20260519), **prod** at
  `2024100711.04` (Build 20260525), and **dev** at `2024100715` (4.5.15, Build 20261005, read by the reviewer on
  2026-11-25). The dev build is used only for Pass B (J3, V805). Every add-on, including `report_allbackups` and the
  theme, is at the commit that matches what legacy runs. **`local_githubsync` is excluded**, because E7 removes it from
  legacy (G1).
- **How (built 2026-11-25 for prod):** `Containerfile.php` now has a code-free `runtime` stage (`--target runtime`);
  `ops/replatform/Containerfile.php-exact` adds the context made by `prepare-exact-context.sh` from the read-only code
  copy; web and cron are built from it with `PHP_IMAGE`, as usual. The context drops `local/githubsync` (G1) and the
  top-level entries that aren't upstream Moodle at legacy's commit: `config/`, `example.versions.env`, `info/` (a PHP
  configuration checker, publicly reachable on prod and test but self-disabled), `last_migration_timestamp`,
  `migrate-courses/`, `openshift/` and `vendor/` (Composer development files, loaded only for developer-mode error pages).
- **Prove it.** Compare checksums of the image's code tree with the legacy pod's `/var/www/html`, excluding `config.php` and
  the custom webroot files, which are not carried over (Q8). **Prod, 2026-11-25:** all 30,197 files in the image are
  byte-identical to the pod's; the 165 legacy files not in the image are exactly the exclusions above. Every add-on's `version.php` must **equal** `config_plugins` in
  the source dump.
- **System packages:** `unoconv` and Ghostscript (§5.11); nginx 1.30.7 or later (§5.1).
- **C14, conversion runtime:** `ops/replatform/Containerfile.convert`. It has PHP 8.3 with `mysqli` **and**
  `pgsql`/`pdo_pgsql`, plus the exact Moodle code for each environment. It runs `tool_dbtransfer` in both directions; client
  versions are recorded.
- **The outbound guard (C5).** In `config.openshift.php`, unless `getenv('MOODLE_OUTBOUND') === 'on'`:
  - `$CFG->noemailever = true;` and `$CFG->enablewebservices = 0;`
  - `$CFG->forced_plugin_settings['local_psaelmsync']`: `apiurl` and `completion_apiurl` are set to
    `http://127.0.0.1:9/outbound-disabled`; `apitoken` and `completion_apitoken` to `''`; `enabled` to `0`;
    `notificationemails` to `''`;
  - `local_githubsync` is not in the image (G1, E7). Its manual sync page and file editor send requests even with a blank
    token, so the plugin is removed rather than configured off (V503);
  - **reviewer-only administration (S15, G2):** `$CFG->siteadmins` is forced to the account ids in
    `MOODLE_REVIEWER_ADMINS`, so web maintenance admits only the named reviewers. This applies only while the guard is on;
    the commit point (`MOODLE_OUTBOUND=on`) returns site administration to the database's own setting;
  - `$CFG->scheduled_tasks` disables the `local_psaelmsync` tasks. Verify the 4.5 syntax.
  - `ops/replatform/check-outbound-guard.php` prints the effective values and runs at every checkpoint.
  - *Implemented 2026-11-25 and verified on the local prod copy:* with the guard on, every item above holds (both ELM
    URLs dead, tokens and notification emails empty, both ELM tasks disabled, only the named reviewer is a site admin,
    `nokeygeneration` on, `local_githubsync` absent); with `MOODLE_OUTBOUND=on`, the database's own values return. The
    ELM completion observer never checks `enabled`, so the dead `completion_apiurl` is what stops it.
- **Admins on a guarded copy** must not mark real courses complete. Acceptance uses **synthetic** records (§15, RB11).
- Decide each legacy setting in §5.11 and record the decision in §16.
- A migrated site gets its own Valkey cache configuration; `muc/config.php` is never copied.
- **Encryption key (V602):** when `install.enabled=false` (a migrated site, whose key is copied from legacy `secret/`),
  `config.openshift.php` sets `$CFG->nokeygeneration = true`. A missing or unrestored key then fails loudly
  (`encryption_nokey`) instead of Moodle generating a new key and leaving encrypted values unreadable.
- **Trash (J2, V802):** the new stack keeps Moodle's stock trash cleanup. v0.8's `$CFG->fileslastcleanup` override is
  withdrawn, and the backup job never deletes live files (C8).

### 8.3 Migration and recovery tooling (reviewed; `ops/replatform/` is deleted after Phase 5, `ops/backup/` is kept)
**Forward**
- `migrate-config.php`: the source-side `config.php` for `tool_dbtransfer` (MariaDB, prefix `''`, a scratch dataroot).
- `local-pipeline.sh`:
  1. Restore the dump into MariaDB 10.6.20.
  2. Run `check_database_schema.php`; expect only the §5.2 items.
  3. In the local copy only, drop the reviewed extra tables **and the trigger** (O4). If the source predates E7, run the
     E7 uninstall in the copy, including its `upgrade.php` hash refresh (G1).
  3a. In the local copy only, fill NULLs in XMLDB NOT NULL columns with Moodle's default (`xmldb-notnull.py`, §5.2), and
     record each change for `expected-differences.md`.
  4. **Stop if any version differs** from the image (S7).
  5. Run `migrate.php --dbtype=pgsql --prefix=mdl_ …` with the C14 runtime.
  6. `pg_dump -Fc`.
- `compare-content.sh` (R12), built as `compare-content.php` with `compare-local.sh`: reads both databases through
  Moodle's own DML (so each side's prefix and driver are handled the same way), merges them in id order, and hashes
  every row with SHA-256 over all columns. A column binary on one side and text on the other compares as raw bytes;
  numbers compare by value. It reports table names, row ids and column names only, never values. `expected-differences.md` lists each accepted difference:
  - `log_display` (rebuilt by `tool_dbtransfer`);
  - `search_simpledb_index` (rebuilt on the target with `search/cli/indexer.php --reindex`, never compared);
  - the dropped tables and trigger;
  - `local_githubsync`'s tables and settings, when the source predates E7, and the hash and cache-revision rows its
    `upgrade.php` refresh changes;
  - the NULLs filled with XMLDB defaults (step 3a, `normalised-nulls-<env>.tsv`).

  Any difference not on the list is a no-go.
- **moodledata copy (O1):** `referenced-files.sql` lists the distinct `contenthash` values in `files` (excluding `.`).
  `moodledata-copy-job.yaml` mounts the legacy PVC **read-only** and copies `filedir` with `rsync --files-from=<that list>`.
  Durable dataroot items (RB07) go per `dataroot-inventory.md`:
  - `lang/` is copied;
  - `secret/` is copied, so values encrypted with Moodle's key stay readable;
  - quarantine folders, `muc/`, caches, sessions, temp, lock and `trashdir` are not copied.
- `reverse-precheck.sh <postgres>` (RB08): finds values distinct in Postgres that would collide in a unique index under
  legacy's `utf8mb4_unicode_ci` (case- and accent-insensitive), using an ICU primary-strength collation. It reports index
  names and counts, never values. An early warning only: the reverse import stays the final check.
- `check-filedir`: every referenced `contenthash` exists in the target with the right size, and its SHA-1 equals its name.
  The known missing files (prod 3, test 9) are listed in `expected-differences.md`. After a restore from a nightly set, any
  gap other than the manifest's recorded source gaps is a failure.

**Recovery sets (S12, V602, V603; in `ops/backup/`, kept after Phase 5, V806)**
- `recovery-set-manifest`: written by each nightly backup and by the window's recovery set. It names the database target
  (the window's backup label, or a nightly set's restore point with its timeline, base backup label and database system
  identifier), the file set and its reference inventory's count and checksum, any source gaps, the durable items, the chart
  values and image digest, the Secret names, and every checksum.
- `moodledata-backup` job (C8; it replaces the VolumeSnapshot-based `moodledata-snapshot`, C16): lock, pause and drain,
  restore point, inventory, capture, reopen, coverage and database gates, publish; with rotation and retention. It never
  publishes a set that fails a gate, and never deletes live files.
- `restore-paired.sh <manifest> <empty target>`: restores the database to the manifest's exact target (`--type=name` with
  `--set` and `--target-timeline` for a nightly set; `--set` with `--type=immediate` for the window's set), and refuses if
  the repository's database system identifier differs from the manifest's. It then restores the set's files into `filedir`
  and the durable items, onto **empty** storage. It never borrows `secret/` or `lang/` from a running source. It ends with
  `check-filedir` against the restored database, a login, the language-customisation check and the encryption canary below.
- **Encryption canary** (dev only): a synthetic value encrypted with `\core\encryption::encrypt()` and stored in a
  dedicated, synthetic config row before the backup. After the restore, `\core\encryption::decrypt()` must return it.
  Moodle 4.5 creates a **new** key silently when `secret/key` is missing (`lib/classes/encryption.php`, `get_key()`), so a
  successful boot alone proves nothing. Migrated installs also set `$CFG->nokeygeneration = true` (§8.2), so a missing key
  raises `encryption_nokey` instead.

**Safety and state**
- `state-capture.sh <name>` / `state-restore.sh <name>` (S14): write, or restore exactly, an immutable named capture
  (`precutover`, `prereturn`). A capture holds maintenance mode, cron replicas, all Route YAML, the health monitor, replica
  counts and `DB_NAME` for each consumer. The output is private (S9).
- `writer-fence.sh` / `writer-unfence.sh` (S13, DR04, V501): work from an inventory of every ingress path (public,
  temporary and restricted Routes) and every writer (web, php, cron, application CronJobs and Jobs). The fence script:
  1. moves the Routes to the fence target;
  2. runs `helm upgrade` with the fenced profile, falling back to an imperative scale-to-0 and suspend if Helm fails, then
     retries the upgrade;
  3. runs `verify-fenced.sh`.

  Postgres stays up. Neither script needs the new application to respond. `writer-unfence.sh` upgrades with the normal
  profile.
- `verify-fenced.sh` (V502): **no SQL.** Checks that every application controller is desired at 0 with 0 pods, no
  application Job is active, every application CronJob is suspended, and no Route reaches the new application. Run it
  after every upgrade while fenced.
- `full-shutdown.sh` / `full-start.sh`: the writer fence plus `PostgresCluster.spec.shutdown`, and the reverse.
- `fence-target`: a static maintenance page the Routes can point at (legacy `maintenance-message`, or the chart's own page).
  The choice is decided and rehearsed in Pass B.
- `restrict-routes.sh <routes> <reviewer-ips>` / `unrestrict-routes.sh` (S15, DR08, DR09): add or remove
  `haproxy.router.openshift.io/ip_whitelist` on the named Routes. Hostnames stay the same, so SSO callbacks keep working.
- `reviewer-write-check.sql`: before the commit point, lists log-store write events by users outside the reviewer list.
  Expect none.
- `recovery-package.sh` (S8, RB09): export legacy manifests, ConfigMaps, Secret names (values only into the private
  folder), image digests (pulled and saved), and a read-only copy of the `moodle-app-data` code PVC. The result is private
  and checksummed.

**Return (D3, RB13)**
- `bailout-dump-check.sh`: accepts only a single-database `mariadb-dump`, without `--databases`. It rejects `USE`,
  `CREATE DATABASE`, `DROP DATABASE` and any statement naming another schema. It reports the table count and checksums.
- `bailout-import.sh`:
  1. As an approved E5 step, create the account `moodle_bailout_import` with privileges on `moodle_bailout.*` **only**.
  2. Load the checked dump through that account.
  3. Record progress so a retry cannot run against the wrong database.
  4. Drop the account afterwards.
- `db-consumers.md`: the reviewed inventory of everything that selects legacy's database. That is php and cron (via
  `DB_NAME`), the database backup (`moodle-db-backup-storage-config`), and anything else the pre-phase re-run of Phase 0
  finds.
- `bailout-switch.sh` / `bailout-unswitch.sh` (D3, DR01, DR02, DR05):
  1. `GRANT ALL PRIVILEGES ON moodle_bailout.* TO 'moodle'@'%'`, then prove a php pod can connect to it as `moodle` before
     anything switches.
  2. `oc set env deploy/php deploy/cron DB_NAME=moodle_bailout` (cron stays at 0), and the same for any other consumer in
     `db-consumers.md`. Wait until ready.
  3. Prove every consumer's database (V506):
     - **php:** run `which-db.php` in each pod to print the effective `$CFG->dbname`;
     - **cron (still at 0):** check the Deployment template's `DB_NAME`, then run a probe pod built from cron's own pod
       template with its command overridden, so neither the cron loop nor its wrapper runs:
       `oc debug deploy/cron --one-container -- php /var/www/html/ops/which-db.php`. It must print `moodle_bailout` and
       connect;
     - **any other consumer** in `db-consumers.md`: its own check.

     A consumer with no evidence fails the handover.
  4. Retarget the backup (`mariadb=mariadb-galera:3306/moodle_bailout`) and restart its pod.

  The undo reverses each step from the `prereturn` capture: `DB_NAME=moodle`, the original backup target, then
  `REVOKE ALL PRIVILEGES ON moodle_bailout.* FROM 'moodle'@'%'`.
- **Legacy fence for an abandoned return, in two tiers (V504, V601, H3).** `maintenance.php` loads Moodle's configuration
  and connects to the database before it reads `--enable`, so it can't be the fence when legacy PHP or Galera has failed.
  - `legacy-fence-infra.sh` (**required; OpenShift API only**): points every Route in the `prereturn` capture that
    reaches legacy at the static fence page, and confirms legacy cron is desired at 0 with 0 pods.
  - `verify-legacy-fenced.sh` (**no PHP, no SQL**). The invariant is by backend (V704): **no Route in the inventory
    reaches legacy** web, php or their Services. During the abandonment the public Routes target the fence page; after
    resumption they target the new stack, which also satisfies it. Legacy cron is at 0 with 0 pods, and no legacy Job or
    CronJob that runs Moodle code is active. This stops **new** ingress only; it does not prove that requests legacy
    had already accepted have finished (V702), which is why cleanup starts with drain.
  - `legacy-cleanup.sh` (**ordered; each step requires the previous one**, V702):
    1. **Maintenance and drain:** `maintenance.php --enable` on legacy (CLI maintenance, which also blocks any request
       arriving through an internal Service), then wait until no legacy php request or Moodle CLI process is running.
       Needs legacy PHP and Galera.
    2. **Switch back and prove it:** `bailout-unswitch.sh` (`DB_NAME=moodle` on php, cron and every consumer in
       `db-consumers.md`; the original backup target), then `which-db.php` on every php pod and the cron probe must show
       `moodle`.
    3. **Frozen checksums:** `frozen-checksums.sql` must match the §14.0 record, taken **after** the switch.
    4. **Remove the return's resources:** `REVOKE` the grant on `moodle_bailout.*`, then drop the import account and
       `DROP DATABASE moodle_bailout`, now that no consumer selects it.

    If a step can't run, **it and every later step wait**, and nothing is changed partially: until step 1 succeeds,
    legacy's database configuration (`DB_NAME`, the grant, the backup target) is left exactly as it was. The script
    records where it stopped, and why, in `pending-cleanup.md`; re-running it resumes from that step.
  - **While `pending-cleanup.md` lists anything:** no Route reaches legacy, legacy cron stays at 0, and legacy is not
    reopened, is not a return target, and is not the last resort. The original `moodle` database is preserved, and
    `moodle_bailout` is kept.
- `frozen-checksums.sql`: per-table `CHECKSUM TABLE` of the frozen `moodle`, taken at `prereturn` and compared after any
  abandoned return (V504), after the consumers have been switched back (V702). If Galera is unavailable it waits, as
  pending cleanup (V601).
- `unique-conflicts.md`: how to read and resolve a unique-key failure in the reverse conversion (RB08). Every resolution is
  an owner decision.
- `quiescence-pg.sql` (RB05; **returns only**, V502): a fresh `pg_stat_activity` read, checked against an allowlist of our
  management sessions. Write counters are reported as supporting evidence only. A failure stops the return; it is never
  part of an abort.
- `elm-reconcile.md` (DR06, V605): compares three sources over a reconciliation window:
  - ELM's records of received completions, obtained by the owner as the ELM contact (Q19);
  - Moodle's `course_completions`;
  - `local_psaelmsync_logs`.

  It classifies each completion as received and logged, received but not logged (interrupted), logged but not received, or
  completed but never sent. **Nothing is re-sent blindly:** a completion is sent again only after ELM's records show it
  wasn't received. Ambiguous cases are decided with ELM; anything unresolved after 5 business days goes to the owner, who
  records the outcome.

  The window depends on how the return ended:
  - **successful return:** from the §13.3 baseline to the §14.1 end-mark;
  - **abandoned return:** from the fence start minus a margin (the longest observed cron task or request, at least
    15 minutes) to the moment the new site resumed. A request or cron task interrupted by the fence can leave a
    completion saved but never sent, or sent but never logged, and the plugin's `process_course_completion` task does not
    replay anything (its `execute()` is empty).
- **Removed in v0.4:** `bailout-swap.sql` / `bailout-unswap.sql` (RB01).

### 8.4 Full local rehearsal
Use the **final post-fix prod dump**, which includes the trigger, and the test dump. The local stack runs on a Podman network
created with `--internal`, so it has no route to the internet.
1. Restore and run the schema check. Expect **only** the §5.2 items. Drop the extra tables and the trigger in the copy.
2. Run `tool_dbtransfer` into Postgres (C14 runtime) and time it. Run `compare-content.sh`: only the expected differences.
3. Boot psa-moodle locally against the Postgres copy with the referenced moodledata. **First boot, prod, 2026-11-25** (exact
   image, no files yet): `upgrade.php --is-pending` reports no upgrade needed; `check_database_schema.php` says "Database
   structure is ok" (the §5.2 drift is gone on Postgres); the login page renders with the `bcgovpsa` theme and the "BC
   Government Login" button; the site starts in maintenance, because the freeze's `maintenance_enabled = 'cli mode'` is
   carried over and only `maintenance.php --disable` clears it. Status checks: cron not running (no cron locally), one
   queued ad hoc task, and `registration_cron_task` at the maximum fail delay, which it already is in prod. **With files
   (2026-11-25):** a read-only copy of the referenced files (8,710 of 8,772, 2.4 GiB, every SHA-1 correct) plus `secret/`
   and `lang/` (empty: prod's language customisations live only in `tool_customlang`). The 62 missing are the 3 known
   (§5.3) plus 59 referenced in the 18 November database but deleted and purged from prod since, the skew of copying
   files a week after the dump; a real window takes both at the same freeze. Moodle used prod's copied key with
   `nokeygeneration` on. Check:
   - `admin/index.php` shows **no pending upgrade**;
   - the environment check passes;
   - the site starts in maintenance;
   - pages work.
4. **Guard test (R2):** with the guard on, complete a **synthetic** course as a synthetic user. Confirm the ELM POST went to
   the dead address and nothing else, and that no email left. Record the cleanup: delete the synthetic records, or reload the
   baseline. `ops/replatform/guard-test.php --run | --cleanup` does this. **Passed on the local prod copy, 2026-11-25:** a
   learner with no ELM enrolment record makes the observer stop at an alert email with no recipients; a learner with a
   synthetic ELM record makes it POST to the dead `completion_apiurl`, and the attempt is logged as `Error`. Cleanup left
   no synthetic course, user or log row.
5. **Reverse direction with new writes (R12, RB08):**
   1. Create a user, a course, an enrolment, an upload, a quiz attempt, a completion, and **two tags differing only by
      accent in one collection**.
   2. Run `tool_dbtransfer` from Postgres into an empty local MariaDB. It must **stop on the tag conflict**; resolve it per
      `unique-conflicts.md` and run it again.
   3. Run `compare-content.sh`, then boot the legacy code against the result. Confirm the records exist and there is no
      pending upgrade. Create another record to prove IDs continue correctly.
6. **Import safety (RB13):** run `bailout-dump-check.sh` against a dump made with `--databases`; it must reject it. Load a
   good dump through the restricted account into a local `moodle_bailout`. Prove that a planted `INSERT INTO moodle.…` is
   denied and that a copy of the "frozen" `moodle` is unchanged.
7. **GitHub (V503):** confirm the image has no `local_githubsync`, and that a copy restored from a pre-E7 dump has none of
   its tables or settings after the pipeline. On a copy that **has** HTTPS egress (the dev profile, not `--internal`), its
   former URLs return 404, and no connection to GitHub is attempted.
8. **Moodledata backup (V801–V803),** with the job image's own tools, against a local Postgres copy, local php and cron,
   and a local moodledata:
   1. **the pause:** web requests get the maintenance page without opening a database connection; the cron loop starts no
      `cron.php`; a request still running when the pause starts holds the drain until it ends; each 5-minute limit reopens
      the site and skips the night;
   2. **the target's inventory:** a file uploaded just before the pause, after the previous run, is in the inventory and the
      set. The review's V801 sequence (an upload, a file-record copy in flight, a deletion, then `recover_file()`) arranged
      around the pause leaves no hash required at the restore point outside the set;
   3. **negative test:** remove one inventory hash from a staged set; the hash is required at the restore point, and the
      set is **not** published;
   4. **a source gap:** a referenced hash deleted from the live volume before a run is reported as a source gap and alerts;
   5. **overlap:** two runs started together: the second exits on the lock and changes nothing. A run whose database
      session is cut stops before its next change. A killed run's maintenance file is removed by the cron loop after
      15 minutes, and its staging folder is left alone until its deadline has passed;
   6. a run interrupted at each step, a space-short run that prunes to the floor of 3, and a run that can't start;
   7. an unchanged hash is the **same inode** in consecutive sets.
9. Write the measured timings into §13.

**Exit gate:** reviewers sign off v1.0 of this runbook, and the owner approves the start of Phase 2.

## 9. Phase 2: 950003-dev (the only place for experiments)

- **2.0 Prerequisites.**
  - **E4, GitHub (once, for all environments):**
    - disable legacy `build.yml` and cancel any queued or running runs;
    - confirm `scheduled-rebuild.yml` is still disabled;
    - put psa-moodle's deploy workflow under C13, with required reviewers;
    - add branch protection on legacy `950003-test` and `950003-prod`.

    *Restoration condition:* re-enable only if the replatform is abandoned for an environment, and only after its pipeline is
    fixed.
  - **E4, dev:** scale the dev pod-health-monitor to 0. *Restoration condition:* scale to 1 if the replatform of that
    namespace is abandoned.
  - **Repair legacy dev (Q17)** as its own approved dev-only step: Routes back on `web`. Galera read 5/5, Primary and Synced,
    on 2026-11-25; re-check it before Pass B.
  - **E7 rehearsal:** uninstall `local_githubsync` in legacy dev with the exact E7 commands, and roll it back once. Then
    schedule E7 for test and prod in the same week, before §10.
  - **Recovery package and restart proof (S8, RB09):** build the package for dev. From it alone, with the old pipeline
    untouched, start fresh legacy php, web and cron pods (delete one pod of each). Prove the site works. Repeat after
    draining a node, if the platform allows it. The test and prod packages are proven by their Pass C fixtures (J3).
  - **Egress proof (C15):** with `externalEgress=off`, show the application cannot reach the internet while backup checks
    still reach the Kubernetes API.
  - **Rehearsal matrix (J3, V805).** No rehearsal returns a database to code other than its own (S7):

    | Rehearsal | Legacy code | Source database | Conversion runtime and new image | Returns into |
    |---|---|---|---|---|
    | Pass A | n/a | none (empty install) | prod build | n/a |
    | Pass B (twice) | legacy dev as deployed: 4.5.15, `2024100715` | legacy dev's own | dev build | legacy dev's own pods |
    | Pass C, test | test's recovery package, `2024100711.03` | test's latest verified dump | test build | the test fixture |
    | Pass C, prod | prod's recovery package, `2024100711.04` | prod's post-fix dump | prod build | the prod fixture |

  - **Isolated legacy fixture for Pass C,** one per target, each built as its own approved dev change:
    - a separate database on legacy dev's Galera (the same MariaDB 10.6.20), loaded from the target's dump, after checking
      Galera's free space. Legacy dev's own database is never touched, and never downgraded;
    - legacy php, web and cron started from the target's **recovery package** alone (its images by digest and its
      configuration, with `DB_NAME` set to the fixture database). This is also that package's restart proof (S8). The
      fixture keeps sessions and caches on its own volume instead of legacy dev's Redis: the one recorded difference from
      the package;
    - **distinct names and labels,** so that no legacy dev Service, Route or NetworkPolicy selects a fixture pod and no
      fixture object selects a legacy dev pod (`check-collisions.sh`);
    - a moodledata PVC of about 4 GiB with the target's referenced files, `secret/` and `lang/`;
    - no public Route; at most a restricted temporary Route for reviewer addresses (S15). Reviewers sign in with the local
      admin account, because SSO is registered only for the target's own hostnames;
    - an egress NetworkPolicy that selects only the fixture's pods and allows DNS and legacy dev's Galera pods on port
      3306, nothing else. Before loading, confirm no other policy grants those pods egress;
    - dev's storage (28.66 GiB free) holds one fixture at a time beside Pass C's new stack; Pass A's measurements confirm
      it. Each fixture is removed after its pass.
- **Pass A: coexistence with an empty install.**
  - `helm install psa-moodle` with `install.enabled=true`, the temporary host, `outbound=off` and `externalEgress=off`.
  - Verify the legacy object list and the legacy site are **unchanged**; compare before and after.
  - Record **admitted** requests of every pod, including sidecars, rollout surge and backup Jobs, **in the quota class each
    one is actually charged to** (DR07). These numbers finalise the D1 request (§5.4).
  - Record the actual Postgres collation (RB08).
  - Exercise:
    - a pgBackRest backup, and the repository's peak use under the time-based retention schedule (C8);
    - a restore drill, with an explicit recovery target (C7);
    - pod-kill and PDB behaviour;
    - alerts;
    - **the writer fence and the full shutdown**, and their reverses, with quota measured in each state (RB04, DR04).
  - **Undo:** `helm uninstall psa-moodle`; then delete the listed `psa-moodle-*` PVCs, the PostgresCluster and the kept
    Secrets.
- **Pass B: dress rehearsal of the cutover (§13) and the return (§14).** Legacy dev is the source, at its deployed 4.5.15
  with the dev build (J3), and its Routes play the public Routes. Record the starting state (S14) first. Each run must
  include:
  - a rollback at **every** checkpoint (CP1, CP2, CP3), ending in exactly the recorded state;
  - a rollback with **new PHP down**, with **new Postgres down**, and after a **failed Helm rollout** (S13; the old site's
    return must not need the new site);
  - the **restricted Routes** (S15): only reviewer addresses reach the copy, SSO works on the real hostname, and the write
    check finds nobody else (DR08, DR09);
  - one complete forward run to reopening, with the commit point recorded before it happens (S11);
  - a return (§14) that includes:
    - an **import interrupted halfway**, recovered by dropping `moodle_bailout`, with the frozen `moodle` proven untouched;
    - an **out-of-scope SQL statement denied**;
    - a **writer fence with new PHP down**, followed by a successful extraction from the still-running Postgres (DR04);
    - the **handover**: the runtime grant, `DB_NAME` on php and cron, `which-db.php` on every consumer, the backup retarget,
      and the full undo (DR01, DR02, DR05);
    - an **ELM reconciliation dry run** against a mock endpoint, including a request interrupted between sending and
      logging (DR06);
    - a **validation failure after the handover**, undone with `bailout-unswitch.sh`, with the new site resumed and no work
      lost;
    - a complete return to legacy dev, ending with legacy reopened by its own approval;
  - **representative new writes** before the return: uploads, edits and deletes, a course restore, a quiz attempt,
    synthetic completions, accent-distinct tags, and fresh IDs (RB08, RB11);
  - a check that legacy serves the CLI maintenance page;
  - the fourth review's scenarios (V501–V508):
    1. a fenced `helm upgrade` (with `outbound=off`), including a failed upgrade and a retry, with no application writer
       reappearing throughout an extraction;
    2. a precommit abort with the new Postgres **unavailable for the whole procedure**;
    3. GitHub: the plugin is absent, and no request leaves for GitHub under the HTTPS-capable CP3 profile;
    4. an abandoned return **after** legacy web validation, with a reviewer session left refreshing, and the frozen
       `moodle` proven unchanged;
    5. the Route restricted before import, and a non-reviewer admin from an allowed address refused;
    6. the cron database proven by the probe while cron stays at 0;
    7. the snapshot rotation, including an interrupted run, and every restore state within the resource budget.
  - the fifth to seventh reviews' scenarios (V601–V605, V701–V705, V801–V806):
    1. **an abandoned return with legacy PHP unavailable** for the whole procedure (legacy php scaled to 0 in dev):
       `legacy-fence-infra.sh` and `verify-legacy-fenced.sh` succeed, the new stack resumes, `legacy-cleanup.sh` stops at
       step 1, and legacy's `DB_NAME`, grant and backup target are **unchanged** (V702);
    2. **an abandoned return with Galera unreachable** for the whole procedure. Galera is made unreachable **without
       stopping or restarting it**: its client Service's selector is patched to match nothing, and the tooling's
       database target is pointed at a pod that doesn't exist. The new stack resumes; cleanup stops at step 1 with nothing
       changed. Then restore the Service, re-run `legacy-cleanup.sh`, and see it complete steps 1–4 in order, with the
       frozen `moodle` unchanged;
    3. **a long legacy request still running** when the Routes move (a slow synthetic request from a reviewer address):
       cleanup waits at step 1's drain until it finishes (V702);
    4. after resumption, `verify-legacy-fenced.sh` passes with the public Routes on the new stack (V704);
    5. the existing abandonment after legacy web validation (scenario 4 above) still passes;
    6. **ELM after an abandoned return** (mock endpoint): fence while one completion's request is in flight and another
       has been received but not logged; abandon; reconciliation finds both, re-sends only the unreceived one, and sends
       nothing twice;
    7. **backup capacity:** replacement activity (upload, then delete or replace, at the supported daily allowance)
       over a full rotation (runs started by hand, K1), an interrupted run, and a space-short run that prunes to the floor of 3 and alerts, all
       within the destination's size. Record the peak space used;
    8. **the backup pause (V801–V804)** on the real stack:
       - uploads, file-record copies and deletions right up to the pause and straight after it, with Moodle's own trash
         cleanup on its schedule: every published set restores to its restore point with every referenced file;
       - a long request holding the drain to its limit: the site reopens, the night is skipped, and the alert fires;
       - two runs started together, and a run killed during the pause (the cron loop reopens the site within 15 minutes);
       - delayed archiving (the repository host scaled to 0 during a run): the set waits, isn't published, and the
         previous one is kept;
       - Postgres down during a run: the site reopens and nothing is published;
       - a Postgres failover between two sets, then a restore of the older set to its recorded timeline.

  Time everything. From the measured durations, set a **latest-abort time** for each window. **Do this twice cleanly.**
- **Pass C: production-scale acceptance, once per target: test first, then prod (J3).**
  - Build the target's isolated legacy fixture (above) and prove the site works from its recovery package alone (S8).
  - Load the target's database (through the local pipeline, with that target's conversion runtime) and its full referenced
    file set (prod about 3 GiB, test about 1.7 GiB) into the new dev stack running the **target's image**, with
    `outbound=off` and `externalEgress=off`.
  - Run §15 and compare page timings with the live environment.
  - Demonstrate the S12 combined restore from a **named recovery set** with `restore-paired.sh`: retrieve it
    independently, restore it **onto empty storage** at the manifest's enforced target, boot Moodle, and run
    `check-filedir` and login (V602, V603). Include:
    - an upload and a deletion just before and just after a nightly set's pause; confirm the restored site matches the
      database at the restore point, and that every file it references is present;
    - a synthetic **language customisation** and the **encryption canary**, both verified after the restore;
    - `secret/` and `lang/` taken only from the recovery set, never from the running source.

    Record the time taken and the complete-site recovery point (H1).
  - Run a full return (§14) **into the fixture's legacy pods** at this size, and record its duration and storage use
    (RB07). The returned database never meets code other than its own (S7).
- **Soak: two nights, alongside Pass B and Pass C, not after them (K1).** A week of an idle dev site adds little, so what
  a week would show is triggered instead, and test's bail-out window is prod's soak with real use (§11 needs it closed):
  - **every scheduled task run once** with `admin/cli/scheduled_task.php --execute=…`, guard on and no internet; `task_log`
    shows no failures and no outbound attempt;
  - a pgBackRest full, differential and incremental backup **triggered by hand**; the repository's peak use measured;
  - backup Jobs started by hand from the CronJob template until **8 or more sets** exist, so rotation is exercised
    (Pass B scenario 7);
  - **every alert fired once on purpose** (a failed backup, a killed pod, a filling volume) and received (Q14);
  - **two real 02:30 pauses** on the prod-sized Pass C stack, with durations recorded. Night 1 is the first run after the
    window's set; night 2 is the first ordinary run that links unchanged files from the previous night;
  - **48 hours of metrics:** no restarts, and flat memory in php, cron, Valkey and Postgres.

  The stack must be in its normal state at 02:30 on both nights; Pass B fences are scheduled around that.
- **Operator checklist:** a one-page checklist per window, kept beside this runbook, so a tired operator doesn't have to
  reconcile §11, §13 and §14.

**Exit gate:** two clean Pass B runs as above; Pass C passed for each target (test before test's window, prod before
prod's); measured window, return and pause durations the owner accepts; the S12 restore demonstrated; and sign-off from
reviewers and the owner.

## 10. Phase 3: 950003-test (production-grade)

- **Before:**
  - tell the course developers about the window and the freeze on site-level administration (Q20); they already know
    automated course backups haven't run since May (Q21); and that the new site shows a maintenance page for about a
    minute at 02:30 each night while its backup runs (J1);
  - agree the window: from 17:00 Pacific, running overnight if needed; the site must be back by business hours (K2);
  - **E7 done in both test and prod** (G1);
  - take fresh verified backups of the database **and** moodledata;
  - build the test recovery package (S8), and pass Pass C for test (J3);
  - provision and verify test's static fence page (S13; test has none as of 2026-11-25);
  - confirm the quota (test fits).
- **E4 in test:** scale test's pod-health-monitor to 0 before the new stack is installed.
- **Some days before:** deploy the new stack beside legacy with the **test image (`.03`)**, `install=false`, `outbound=off`
  and `cron=off`. Pre-copy the referenced files with the copy Job; that is safe while legacy is live, because filedir is
  append-only.
- **The window:** follow §13, starting with `state-capture.sh` (test may be in web maintenance; S14). SSO only works on the
  public hostname, so it is checked at CP3.
- **Bail-out window: 3 business days (D2).** Legacy test stays frozen and running, with cron at 0. Course developers work on
  the new stack, and site-level administration is frozen (Q20).
- **Prove the course flow:** a course backed up from the new test must restore into legacy prod.
- **Build alignment:** test moves to prod's build (`.04`) in its own window, only after **both** bail-out windows have closed.

**Exit gate:** sign-off from the owner and the course developers, and the bail-out window closed.

## 11. Phase 4: 950003-prod

### 11.1 Before the window
- **Submit the D1 temporary quota request early.** The
  [draft](quota-request-950003-prod-temporary.md) asks for 4 → 7 cores and 96 → 144 GiB, until decommission, with three
  Postgres instances and no restore drill in prod (G3). Update it with Pass A's admitted numbers if they're available.
- **ELM contact (Q19):** the owner. Before the window, confirm with ELM how received completions can be checked.
- **Tell the admins** that site-level administration is frozen for the bail-out window (Q20).
- **Tell learners** and agree the window (from 17:00 Pacific, K2), including the nightly backup pause at 02:30 (J1).
- **E4 in prod:** scale prod's pod-health-monitor to 0 before the new stack is installed.
- Build the prod recovery package (S8), and pass Pass C for prod (J3).
- Provision and verify prod's static fence page (S13; scaled to 0 as of 2026-11-25).
- Deploy the new stack in its smallest shape with the **prod image (`.04`)**, `install=false`, `outbound=off`, `cron=off`.
  Pre-copy the referenced files.
- Recompute the quota with admitted requests at T−1d.

### 11.2 Capacity in the window (rehearsed in dev Pass B)
- **Forward:** at the freeze, legacy cron goes to 0 (E2). **Nothing else in legacy is scaled** (D1). Then the new stack is
  scaled to the prod shape within the temporary quota; wait until every pod is ready.
- **Reverse:** §13.4. Legacy dependencies are still running, so there is no cold start.

### 11.3 Window and bail-out
- **Window:** follow §13.
- **Bail-out window: 5 business days (D2).** Legacy stays frozen and running; site-level administration is frozen (Q20).
- **Backups (S12)** are working, as a named recovery set, before reopening.

## 12. Phase 5: decommission (per environment, dev first, after its bail-out window and sign-off)

1. Confirm that the pre-cutover dumps, the referenced-file copies and the recovery package are archived and readable.
2. **Archive the unreferenced files** (O1) from legacy moodledata into the private archive, with a checksum list.
3. Scale the remaining legacy workloads to 0, Galera last, and wait an agreed number of days.
4. Delete the legacy objects **by name from a reviewed list**, never by label or `--all`. PVCs go last.
5. Adopt the public Routes into the chart, and remove the chart's temporary Route.
6. Review the namespace-wide NetworkPolicies (§5.8).
7. Return the temporary quota. Archive the moodle-nginx workflows and mark the repository read-only.
8. Retire a58ce1 (including the learningcurator leftovers) and release ad4087. a58ce1-dev's psa-moodle objects have no Helm
   release records any more, so delete them by name.
9. **Before deleting `ops/replatform/` (V806),** restore a recovery set in dev using only `ops/backup/` and the released
   images. The backup and restore tooling stays.
10. Update `README.md`, `CLAUDE.md` and this runbook.

## 13. The cutover window (used in dev Pass B, test and prod)

The timings are placeholders until Phase 1 measures them. Every step is approved in advance as a set, and each checkpoint
(CP) is an explicit go/no-go call by the owner. Throughout, until §13.3: **new cron is 0, the outbound guard is on.**

### 13.1 Freeze legacy (R3)
| T | Step | Verify | Undo |
|---|---|---|---|
| T−7d | New stack deployed (`install=false`, `outbound=off`, `cron=off`, temporary host **restricted from creation**, S15); the restriction verified from a non-reviewer address before any data is loaded; referenced files pre-copied | Collision check clean; legacy unchanged; non-reviewer refused | `helm uninstall` and delete its PVCs |
| T−1d | Backups verified; recovery package current; comms sent; quota recomputed; laptop on power and wired, sleep disabled | n/a | n/a |
| T0 | **`state-capture.sh precutover`** (S14); note the latest-abort time | Saved privately | n/a |
| T0 | **E1:** `php admin/cli/maintenance.php --enable` in one legacy php pod | Public URLs return the maintenance page to anonymous users **and** an admin session; a web-service call is refused | `state-restore.sh precutover` |
| T0 | **Drain:** wait for running scheduled and ad hoc tasks to finish | No cron or ad hoc PHP processes; no `task_adhoc` rows with a `timestarted`; limit 15 minutes, then the stop rule | n/a |
| T+? | **E2:** scale legacy cron to 0 | Pod gone | Scale to the captured count |
| T+? | **Quiescence:** Galera `wsrep_last_committed` unchanged for 5 minutes; no client connections except ours | Both hold | Find the writer before continuing |
| T+? | Final `mariadb-dump --single-transaction`, verified for footer, table count, checksum and live row counts | As in the mojibake run's `dump.sh` | n/a (read-only) |
| T+? | Final referenced-files delta (list regenerated from the final dump) and durable dataroot items | `rsync` exit 0 | Delete the Job |
| T+? | Local pipeline: restore, schema check, drop extras and trigger in the copy, version check, `tool_dbtransfer`, `compare-content.sh` | Only expected differences | n/a (local) |
| **CP1** | **Go/no-go: is the data correct?** | | No-go: §13.4. **No data lost.** |

### 13.2 Load, check, switch (R7, R8)
| T | Step | Verify | Undo |
|---|---|---|---|
| T+? | Scale the new stack to the target shape within quota (§11.2) | Pods ready; quota not exceeded | §13.4 |
| T+? | `pg_restore` into the new primary; `compare-content.sh` against the frozen source; `check-filedir` | Only expected differences | Drop and recreate the new database; then §13.4 |
| T+? | Site in **web** maintenance; purge caches; rebuild the search index; `check-outbound-guard.php` | No pending upgrade; guard values correct | n/a |
| T+? | Re-verify the temporary Route's restriction (in place since creation, S15); checks by named reviewers through it, with wwwroot on the temporary host | Every response carries `X-PSA-Stack: psa-moodle`; other addresses are refused; a non-reviewer admin is refused | n/a |
| **CP2** | **Go/no-go: does the new site work for admins?** | | §13.4 |
| T+? | Generate exact Route undo patches from the captured YAML. `helm upgrade` wwwroot = public hostname (still maintenance, cron 0, guard on) | Pods ready | `helm rollback` |
| T+? | `restrict-routes.sh` on **both** prod Routes (S15), then **E3:** patch them: `spec.to.name` → `psa-moodle-web`, `spec.port.targetPort` → `http`, timeout annotation `900s`. Certificates untouched | Reviewer addresses get `X-PSA-Stack: psa-moodle`; other addresses are refused; the custom certificate is still served | Undo patches (Routes first), `unrestrict-routes.sh`, then `helm rollback` |
| T+? | Reviewer checks through both public hostnames, including **SSO login**; §15 spot checks with **synthetic** records only; `reviewer-write-check.sql` finds nobody else | | |
| **CP3** | **Go/no-go: open the site?** | | Routes back, then §13.4. **No data lost.** |

### 13.3 The commit point (S11, S12, RB11)
| T | Step | Verify |
|---|---|---|
| T+? | **S12 recovery set:** named pgBackRest backup after the restore, plus the matching moodledata archive and checksums; artifacts read back; the off-site copy written to the owner's encrypted disk and checked against the checksums (Q11) | Each item recorded in the window log |
| T+? | **Record the commit point** in the window log: time, the exact command about to run, and the **ELM baseline** (the latest `local_psaelmsync` log id and time on the new site). From the next step on, going back means §14 | Logged before continuing |
| T+? | `helm upgrade` with `outbound=on` and `cron=on` (this also renders the SMTP egress policy, C9). **This is the commit point, even if the rollout fails part-way** | `check-outbound-guard.php` shows real values; a cron run succeeds |
| T+? | `unrestrict-routes.sh` on both prod Routes; `php admin/cli/maintenance.php --disable` on the new site; announce | Learners and authors can log in; a test email arrives; the first real ELM completion appears in the plugin's log |

### 13.4 Reverse sequence (any rollback before the commit point)
1. **Writer fence (S13),** or a full shutdown if the new database isn't needed:
   - if the Routes were switched, apply the saved undo patches first, or point the Routes at the fence target;
   - run `writer-fence.sh`: the fenced profile, then `verify-fenced.sh`. It uses no SQL, so this works with the new Postgres
     down (V502);
   - run `full-shutdown.sh` as well, if wanted.

   Use `maintenance.php --enable` on the new site only if it responds. Verify that no hostname returns `X-PSA-Stack`.
2. **Legacy dependencies are already running (D1).** Confirm Sentinel reports a master and quorum, redis-proxy is ready,
   and legacy php and web are ready.
3. **Validate legacy before anyone else returns (RB02).** Keep legacy in CLI maintenance behind the fence. If admin checks
   are needed:
   - restrict the public Routes to the reviewers (S15) and point them at legacy;
   - move legacy to web maintenance **behind that restriction** (S14).

   SSO works because these are the registered hostnames.
4. **Separate approval: `state-restore.sh precutover` (S14).** It restores, exactly as captured and without the restriction:
   - maintenance mode (prod: off; test: whatever was recorded, possibly web maintenance);
   - cron replicas;
   - both Routes.
5. The health monitor stays at 0 until the owner decides whether the replatform continues (E4 restoration condition).
6. Afterwards, if wanted, release the new stack with `helm uninstall` (its PVCs are kept until the owner decides).

## 14. Return after the commit point (a second migration, D2)

This is **planned as its own change**: its own approval, window, checks and commit point. It is **not lossless by
guarantee.** ELM deliveries made by the new site cannot be undone, and records valid on Postgres may conflict with legacy's
unique keys (RB08). The frozen `moodle` database is never written. It is available during the bail-out window only: 3
business days for test, 5 for prod.

### 14.0 Decide and prepare
- Owner approval; window and latest-abort time agreed; the ELM contact engaged (Q19).
- Capacity:
  - every Galera PVC has at least twice the database size free;
  - legacy moodledata has free space for the new content hashes plus a stated reserve (RB07; monitor it throughout the
    bail-out window, and alert before the reserve is reached);
  - the temporary quota still holds (D1).
- The recovery package is current (S8); `state-capture.sh prereturn` has run (S14); `frozen-checksums.sql` has recorded
  the frozen `moodle`'s per-table checksums (V504).
- **`reverse-precheck.sh` reports no collisions** (RB08). It also runs **daily through the bail-out window**, so a
  collision is resolved per `unique-conflicts.md` before anyone needs a return, not during one. Proven locally on
  2026-11-25: two synthetic tags differing only by an accent made the reverse conversion stop with `Duplicate entry ...
  for key 'tag_tagnam_uix'`, and the precheck found exactly that collision beforehand.

### 14.1 Stop the new site's writers, keep its database (RB03, RB05, DR04)
1. Optionally, `maintenance.php --enable` on the new site, if it responds.
2. **`writer-fence.sh`** (S13, V501):
   - every Route that reaches the new stack goes to the fence target;
   - `helm upgrade` with the **fenced profile**: writers at 0, application CronJobs suspended, outbound off, so no later
     upgrade can bring a writer back;
   - `verify-fenced.sh`, with no SQL;
   - Postgres **stays up**.
3. **Database quiescence** (returns only, V502): `quiescence-pg.sql` shows only allowlisted management sessions. Write
   statistics are supporting evidence only. If it fails, or the database is unreachable, **stop the return**: either unfence
   the new site, or use the abort path.
   Re-run `verify-fenced.sh` just before the dump starts.
4. **ELM end-mark:** record the last `local_psaelmsync` log id and time, and the latest `course_completions.timecompleted`.
   The completions to reconcile lie between the §13.3 baseline and this mark (DR06).

### 14.2 Convert locally
1. `pg_dump` the new database; restore it into local Postgres.
2. Run `tool_dbtransfer` into an empty local MariaDB 10.6.20 with prefix `''` (C14 runtime, exact code, S7).
   - **If it fails on a unique key (RB08):** stop. List the conflicts and resolve each one per `unique-conflicts.md`, with the
     owner deciding. Then run it again.
3. Run `compare-content.sh` between Postgres and MariaDB.
4. Run `mariadb-dump` **without `--databases`** and validate the result with `bailout-dump-check.sh` (RB13).

### 14.3 Load (E5)
1. Create `moodle_bailout` and the `moodle_bailout_import` account, which has privileges on `moodle_bailout.*` only.
2. Run `bailout-import.sh` through that account.
3. Run `compare-content.sh` against the local MariaDB.

**If anything fails:** `DROP DATABASE moodle_bailout`. The frozen `moodle` is untouched; retry, abandon (below), or stop.

### 14.4 Files and durable state (E5, RB07)
- Copy, add-only, the content hashes referenced in `moodle_bailout.files` that are absent from legacy.
- Handle durable dataroot items per `dataroot-inventory.md`. Changed `lang/` customisations are returned after review. The
  key in `secret/` is unchanged on both sides, because the new stack used the copied key.
- Run `check-filedir` against `moodle_bailout.files`.

### 14.5 Go/no-go 1: is the returned data verified?

### 14.6 Handover (E5, D3, DR01, DR02, DR05)
Run `bailout-switch.sh`, which:
1. grants `moodle@%` privileges on `moodle_bailout.*` and proves it can connect;
2. sets `DB_NAME=moodle_bailout` on php, on cron (still at 0) and on every other consumer in `db-consumers.md`;
3. proves every consumer's database: `which-db.php` in each php pod, and for cron (still at 0) its template plus a probe
   pod with the cron loop disabled (V506);
4. retargets legacy's database backup.

Legacy stays in CLI maintenance (`climaintenance.html` also keeps cron gated), and the public Routes stay on the fence target.
**Undo:** `bailout-unswitch.sh` puts the frozen `moodle` back everywhere, restores the backup target and revokes the grant.

### 14.7 Caches and validation (RB02)
Redis is already running (D1).
1. `purge_caches.php` on legacy.
2. Restrict the public Routes to the reviewers (S15), point them at legacy, then move legacy from CLI to web maintenance
   behind that restriction (S14).
3. Validate through those restricted public Routes only, so SSO uses the registered hostnames (DR09). Check:
   - no pending upgrade, and versions equal;
   - records created on the new stack are present, files included;
   - the local admin login and SSO;
   - a controlled synthetic record gets a fresh ID.

Legacy has **no** outbound guard, so nobody triggers completions during these checks.

### 14.8 Go/no-go 2 and separate approval: reopen legacy
1. **Recovery set first (S12, DR05):** a verified backup of `moodle_bailout` from the retargeted backup job, plus the
   matching moodledata, checksummed, with the off-site copy on the owner's encrypted disk.
2. Run `unrestrict-routes.sh`. Then set the Routes, maintenance mode and cron to the **`precutover`** capture's values: the
   state before the original cutover, not the frozen `prereturn` values. **`DB_NAME` stays `moodle_bailout` on every
   consumer, and the backup stays retargeted.** Only Routes, maintenance mode and cron come from `precutover`. Announce.

**This is the return's commit point.** After it, going back to the new stack is another migration.

### 14.9 ELM reconciliation (RB11, V605)
**This follows every return attempt that fenced the new stack after the commit point, whether the return succeeded or was
abandoned.** With ELM (the owner is the contact, Q19), work through `elm-reconcile.md`. It compares ELM's records of what
it received with Moodle's completion records **and** the local log, over the window for that outcome:
- **successful return:** between the §13.3 baseline and the §14.1 end-mark;
- **abandoned return:** from the fence start minus the margin to the new site's resumption.

That includes requests interrupted between sending and logging (DR06). Nothing is re-sent unless ELM's records show it
wasn't received. Handle duplicates and gaps as agreed. Neither legacy nor the plugin replays anything automatically (the
plugin's `process_course_completion` task has an empty `execute()`). Record the outcome; after an abandonment this is
usually a short check with nothing to resolve.

### Abandon and resume (before 14.8, RB03, V504, V601)
The return can be abandoned at any point before 14.8, losing no work, because no writes were accepted anywhere after the
fence. Abandonment must work **even when legacy PHP or Galera is what failed**, so it never waits on either (H3).
**The order matters:**
1. **Fence legacy with infrastructure only** (`legacy-fence-infra.sh`): every Route that reaches legacy goes to the static
   fence page; legacy cron confirmed at 0 with 0 pods.
2. **`verify-legacy-fenced.sh`** (no PHP, no SQL) must pass: no Route reaches legacy (V704). This is the only legacy
   precondition for resuming. It stops new ingress; work legacy had already accepted is dealt with by cleanup step 5.1.
3. **Resume the new stack:** `writer-unfence.sh` (plus `full-start.sh` if a full shutdown ran): the normal profile,
   `outbound=on`, cron on. Then `state-restore.sh prereturn` for the Routes, which sends them back to the new stack, and
   `maintenance.php --disable` on the new site.
4. **ELM reconciliation for the fence interval** (§14.9, V605), even though the return was abandoned.
5. **Legacy cleanup, strictly in order** (`legacy-cleanup.sh`, V702). Each step needs the previous one to have succeeded:
   1. **maintenance and drain:** `maintenance.php --enable` on legacy (CLI maintenance), then wait until no legacy php
      request or Moodle CLI process is running;
   2. **switch back and prove it** (if 14.6 ran): `bailout-unswitch.sh`, then every consumer in `db-consumers.md` shown
      on `moodle` (`which-db.php` on each php pod, the cron probe, the backup target);
   3. **frozen checksums,** after the switch: every table of the frozen `moodle` matches the checksums recorded in §14.0;
   4. **remove the return's resources** (if 14.3 ran): revoke the grant on `moodle_bailout.*`, drop the import account,
      then `DROP DATABASE moodle_bailout`.

   If a step can't run (legacy PHP down, Galera unavailable, or the drain doesn't finish), **it and every later step
   wait.** Nothing is changed partially: legacy's `DB_NAME`, grant and backup target stay exactly as they were until step
   1 has succeeded. `pending-cleanup.md` records where cleanup stopped and why; re-run `legacy-cleanup.sh` once legacy PHP
   and Galera are available, and it resumes from that step. Steps that don't apply are recorded as skipped.

Legacy ends as it was during the bail-out window: frozen, cron at 0, and no Route reaching it. Until `pending-cleanup.md`
is empty it may lack CLI maintenance, may still name `moodle_bailout`, and its frozen database is unverified, so it is
**not reopened, not a return target and not the last resort** (H3). `moodle_bailout` is kept until step 4. If the frozen
checksums fail to match, stop and treat it as an incident before any further use of legacy.

### Last resort (owner only)
If the new site cannot resume and the return cannot complete:
- legacy goes back on the frozen `moodle` (`bailout-unswitch.sh` if needed), losing all work since reopening. This requires
  Galera available and `frozen-checksums.sql` matching (H3);
- the new stack's database, files and backups are kept for manual recovery;
- ELM is reconciled for every completion the new site sent (§14.9).

## 15. Acceptance checks (each environment)

- **Data, at CP1 and CP2 (frozen baselines, before any activity):**
  - `compare-content.sh` shows only the differences in `expected-differences.md`;
  - `check_database_schema` is clean, apart from the documented items;
  - `check-filedir` finds no missing files except the known ones (prod 3, test 9), and no SHA-1 mismatches;
  - the mojibake census over **text and binary-typed columns**, plus the stray-character check, matches §5.12;
  - the search index is rebuilt on the target and then passes the same census.
- **Which stack answered:** every check confirms the `X-PSA-Stack` header.
- **Outbound (V503):** `local_githubsync` is absent (no code, no tables, no settings), its former URLs return 404, and no
  request leaves for GitHub. `check-outbound-guard.php` shows the guarded values.
- **Reviewer-only access (S15):** other addresses are refused on every restricted Route; a non-reviewer admin from an
  allowed address is refused too (G2); and `reviewer-write-check.sql` finds no writes by anyone outside the reviewer list
  before the commit point.
- **After a return (DR05, V506):** every consumer in `db-consumers.md` reports `moodle_bailout`, cron through its probe;
  legacy's scheduled database backup targets `moodle_bailout` and has completed once, verified.
- **Login:** SSO ("BC Government Login") on the public hostnames and the local admin account.
- **Courses:** course pages, images and files; H5P (`mod_hvp` and core); lessons, books and quizzes, including an attempt;
  grades; search; reports, including `report_allbackups`; document conversion (unoconv, Ghostscript).
- **Completion:** only on **synthetic** courses and users, with the guard on, and with the recorded cleanup applied afterwards
  (RB11).
- **Course flow:** back up a course (`.mbz`) and restore it across environments.
- **Before opening (S12):** a named recovery set with its manifest (database target, file set, `secret/` and `lang/`,
  configuration), artifacts read back, checksums, off-site retrieval evidence, scheduled backups with alerts, and the
  paired restore onto empty storage demonstrated in dev (language customisation and encryption canary verified), with its
  duration.
- **After opening:**
  - a test email is delivered (C9);
  - the first real ELM completion POST succeeds, and ELM confirms receipt (Q3, Q19);
  - `task_log` shows tasks succeeding, and ad hoc tasks drain;
  - no new errors in the PHP and cron logs.

  There is **no** row-count comparison after opening.
- **Platform:** the integrity CronJob passes; alerts reach the recipients (Q14); the PDBs and HPA behave as expected.
- **Cron (C3):** cron runs every minute: the last run is under two minutes old, and `task_log` shows the per-minute tasks.
- **Nightly backup (C8):** the first nights' pauses stay within their limits and publish a usable set.
- **Performance:** login and course-page response times no worse than legacy (prod login was about 130 ms on 2026-11-16).

## 16. Decision log and Phase 0 findings

| Date | Decision | By |
|---|---|---|
| 2026-11-17 | 950003-test is production-grade; dev is the only experiment target | Owner |
| 2026-11-17 | Replatform in place inside 950003 instead of ad4087 or a new project set | Owner |
| 2026-11-18 | Don't fix test's 51 mojibake values (courses that won't be used) | Owner |
| 2026-11-18 | Fix prod mojibake before migration (done 2026-11-18, including binary-typed columns; three explained exceptions accepted) | Owner |
| 2026-11-18 | GitHub sync is unused; disabled on copies; dropped from acceptance | Owner |
| 2026-11-18 | Accept review findings R1–R12 into v0.2 | Owner |
| 2026-11-18 | Freeze with CLI maintenance; never use the legacy maintenance wrapper | v0.2 |
| 2026-11-18 | Pin each environment's image to its legacy build; align test to prod only after both bail-out windows | v0.2 |
| 2026-11-18 | ~~Bail-out swaps databases with one `RENAME TABLE`~~ (superseded on 2026-11-23 by D3) | v0.2 |
| 2026-11-18 | Disable moodle-nginx `scheduled-rebuild.yml` (the weekly dev deploy). Done | Owner |
| 2026-11-18 | Test stays in web maintenance until the week of 2026-11-23 or its replatform; communicated and approved (extended on 2026-11-23: no deadline) | Owner |
| 2026-11-18 | Q18 deferred (done on 2026-11-23) | Owner |
| 2026-11-20 | psa-moodle web image on nginx 1.30.7 (`docker.io/nginx/nginx-unprivileged`, by digest); the a58ce1-dev PoC was patched by hand | Owner |
| 2026-11-23 | Accept second-review findings RB01–RB14 into v0.4 | Owner |
| 2026-11-23 | **D1** One temporary prod request for CPU and storage; legacy dependencies stay running through the bail-out window | Owner |
| 2026-11-23 | **D2** Firm rollback before the commit point; a second migration after it; bail-out windows of 3 (test) and 5 (prod) business days | Owner |
| 2026-11-23 | **D3** Return by switching legacy `config.php` to a verified `moodle_bailout`; no `RENAME TABLE` | Owner |
| 2026-11-23 | **O1** Copy referenced files only; archive the unreferenced set before decommission; investigate only on report | Owner |
| 2026-11-23 | **O2** ~~Leave GitHub sync's task in legacy~~ (superseded the same day by G1: uninstall) | Owner |
| 2026-11-23 | **O3** Test's automated course backups (failing since 2026-05-20): leave to the replatform; tell the developers | Owner |
| 2026-11-23 | **O4** Drop `trg_log_completion_criteria_delete` on the new stack | Owner |
| 2026-11-23 | **Q19** The owner is the ELM contact; **Q20** freeze site-level administration during bail-out windows; **Q21** course developers told about test's automated backups | Owner |
| 2026-11-23 | **Q18 done:** test's health monitor set to `MANUAL_MODE=true` (approved change; backups verified first) | Owner |
| 2026-11-23 | Test may stay in web maintenance with no deadline | Owner |
| 2026-11-23 | Accept third-review findings DR01–DR09 and both procedure points into v0.5 | Owner |
| 2026-11-23 | **The stored GitHub sync credential had long since expired** (DR03); copies also blank it | Owner |
| 2026-11-23 | **Q11** The off-site copy for S12 is the owner's copy on the encrypted laptop disk | Owner |
| 2026-11-23 | Accept fourth-review findings V501–V508 into v0.6 | Owner |
| 2026-11-23 | **G1** Uninstall `local_githubsync` from legacy test and prod (E7); the new image excludes it | Owner |
| 2026-11-23 | **G2** Routes restricted from creation; reviewer-only `siteadmins` in the pre-commit profile (default reviewer: the owner) | Owner |
| 2026-11-23 | **G3** Three Postgres instances in prod, two in test during its parallel run; no restore drill in prod or test during the parallel run; quota draft 4 → 7 cores, 96 → 144 GiB | Owner |
| 2026-11-23 | **G4** Moodledata backups as daily `rsync --link-dest` snapshots, 7 retained (mechanism revised on 2026-11-25 by J1 and J2; still nightly, 7 retained) | Owner |
| 2026-11-24 | Fifth review: Phase 1 preparation may start. Accept findings V601–V605 into v0.7 | Owner |
| 2026-11-24 | **V505 residual risk accepted:** a non-reviewer changing data during review is considered practically nonexistent; not a cutover blocker | Owner |
| 2026-11-24 | **H1** Complete-site recovery point: up to 24 hours if the moodledata volume is lost; minutes if only the database is lost | Owner |
| 2026-11-24 | **H2** Test's moodledata snapshot destination 5 GiB; test at about 93.1 of 96 GiB during its parallel run; prod quota request unchanged | Owner |
| 2026-11-24 | **H3** An abandoned return resumes the new site behind an infrastructure-only legacy fence; legacy isn't reopened or used as a fallback until pending cleanup and the frozen checksums complete | Owner |
| 2026-11-24 | Sixth review: continue Phase 1. Accept findings V701–V705 into v0.8. The v0.7 "T − 60 s" pairing is withdrawn; the moodledata backup job owns the trash and verifies coverage before publishing | Owner |
| 2026-11-25 | Seventh review: continue Phase 1. Accept findings V801–V806 into v0.9. v0.8's live-copy capture and job-owned trash are withdrawn | Owner |
| 2026-11-25 | **J1** Nightly backup pause (CLI maintenance and drain), about a minute at 02:30 Pacific, 10 minutes at most; past a limit, reopen, skip and alert | Owner |
| 2026-11-25 | **J2** The backup job never deletes live files; Moodle's stock trash cleanup stays on | Owner |
| 2026-11-25 | **J3** Rehearsal matrix: Pass B on legacy dev's 4.5.15 with a dev build; Pass C per target on an isolated fixture built from its recovery package | Owner |
| 2026-11-25 | **J4** A nightly pair is guaranteed only within pgBackRest's 8-day retention; alert at 3 days, escalate at 5 | Owner |
| 2026-11-25 | **K1** The dev soak is two nights, run alongside Pass B and Pass C, with weekly and rare events forced by hand instead of waited for; test's bail-out window serves as prod's soak with real use (replaces the one-week soak; for review in v1.0) | Owner |
| 2026-11-25 | **K2** (evidence in §5.13) During the migration weeks the site needs to be available only in business hours, and traffic after 16:00 is negligible. Cutover and return windows start at 17:00 Pacific and may run overnight; latest-abort times are set against the next business morning. J1's pause limits may be raised if Pass B's drains need it | Owner |

**Phase 0 findings (2026-11-18):** see [replatform-950003-phase0-findings.md](replatform-950003-phase0-findings.md).
The facts that change the plan are folded into §5 and §6.

## 17. References
- **Reviews:** [replatform-950003-review.md](replatform-950003-review.md) (v0.1, R1–R12),
  [replatform-950003-rollback-review.md](replatform-950003-rollback-review.md) (v0.3, RB01–RB14) and
  [replatform-950003-v04-review.md](replatform-950003-v04-review.md) (v0.4, DR01–DR09),
  [replatform-950003-v05-review.md](replatform-950003-v05-review.md) (v0.5, V501–V508),
  [replatform-950003-v06-review.md](replatform-950003-v06-review.md) (v0.6, V601–V605),
  [replatform-950003-v07-review.md](replatform-950003-v07-review.md) (v0.7, V701–V705) and
  [replatform-950003-v08-review.md](replatform-950003-v08-review.md) (v0.8, V801–V806).
- **Helm:** [three-way merge](https://helm.sh/docs/faq/changes_since_helm2/#improved-upgrade-strategy-3-way-strategic-merge-patches)
  (an upgrade can restore replicas scaled to 0 outside Helm)
- **Quota draft:** [quota-request-950003-prod-temporary.md](quota-request-950003-prod-temporary.md)
- **Kubernetes:** [NetworkPolicies are additive](https://kubernetes.io/docs/concepts/services-networking/network-policies/#the-two-sorts-of-pod-isolation);
  [quota scopes](https://kubernetes.io/docs/concepts/policy/resource-quotas/#quota-scopes) (`Terminating` needs a pod-level
  `activeDeadlineSeconds`); [CronJob concurrency policy](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/#concurrency-policy)
  (`Forbid` covers only Jobs of the same CronJob)
- **Phase 0:** [replatform-950003-phase0-findings.md](replatform-950003-phase0-findings.md)
- **Moodle:** [Administration via command line, Maintenance mode (4.5)](https://docs.moodle.org/405/en/Administration_via_command_line#Maintenance_mode);
  `MOODLE_405_STABLE` source: [`lib/filestorage/file_system_filedir.php`](https://github.com/moodle/moodle/blob/MOODLE_405_STABLE/lib/filestorage/file_system_filedir.php)
  (`remove_file()`, `recover_file()`, `empty_trash()`, `add_file_from_path()`),
  [`lib/filestorage/file_storage.php`](https://github.com/moodle/moodle/blob/MOODLE_405_STABLE/lib/filestorage/file_storage.php)
  (`cron()`, `$CFG->fileslastcleanup`, `create_file_from_storedfile()`), `lib/db/tasks.php` (`file_trash_cleanup_task`,
  every 6 hours), [`lib/classes/encryption.php`](https://github.com/moodle/moodle/blob/MOODLE_405_STABLE/lib/classes/encryption.php)
  (`get_key()`, `nokeygeneration`), [`lib/setup.php`](https://github.com/moodle/moodle/blob/MOODLE_405_STABLE/lib/setup.php)
  (the `climaintenance.html` check comes before `setup_DB()`) and
  [`lib/classes/cron.php`](https://github.com/moodle/moodle/blob/MOODLE_405_STABLE/lib/classes/cron.php)
  (`run_main_process()` stops in CLI maintenance)
- **MariaDB:** [RENAME TABLE](https://mariadb.com/docs/server/reference/sql-statements/data-definition/rename-table) (tables
  with triggers can't change database);
  [mariadb-dump options](https://mariadb.com/docs/server/clients-and-utilities/backup-restore-and-import-clients/mariadb-dump)
  (`--databases` adds `CREATE DATABASE` and `USE`)
- **PostgreSQL 15:** [statistics](https://www.postgresql.org/docs/15/monitoring-stats.html),
  [collation](https://www.postgresql.org/docs/15/collation.html),
  [continuous archiving and point-in-time recovery](https://www.postgresql.org/docs/15/continuous-archiving.html),
  [`pg_create_restore_point()`](https://www.postgresql.org/docs/15/functions-admin.html#FUNCTIONS-ADMIN-BACKUP),
  [recovery targets](https://www.postgresql.org/docs/15/runtime-config-wal.html#RUNTIME-CONFIG-WAL-RECOVERY-TARGET)
- **pgBackRest:** [restore options](https://pgbackrest.org/command.html#command-restore) (`--type=name`, `--set`,
  `--target-timeline`)
- **rsync:** [`--link-dest`](https://rsync.samba.org/ftp/rsync/rsync.1.html) (files are hard-linked only when their
  preserved attributes match)
- **Crunchy:** [administrative tasks](https://access.crunchydata.com/documentation/postgres-operator/latest/tutorials/cluster-management/administrative-tasks)
  (`spec.shutdown`)
- **Platform docs** (`../platform-developer-docs/src/docs/`):
  - `automation-and-resiliency/request-quota-adjustment-for-openshift-project-set.md` (Example 3)
  - `automation-and-resiliency/namespace-recovery-and-responsibilities.md`
  - `automation-and-resiliency/netapp-backup-restore.md`
  - `platform-automation/pruning.md`
  - `platform-architecture-reference/openshift-network-policies.md`
  - `platform-architecture-reference/platform-storage.md` (only block volumes support snapshots; `netapp-file-backup` is
    backed up by OCIO)
  - `database-and-api-management/postgres-how-to.md`, `database-backup-best-practices.md`
- **This repository:** `CLAUDE.md`; `README.md` ("Environment roles: read this first"); `chart/psa-moodle/templates/`;
  `Containerfile.php`, `Containerfile.web`; `config/moodle/config.openshift.php`; `.github/workflows/deploy.yml`;
  `scripts/ops/`; `docs/phase3-deploy.md` to `docs/phase6-backups.md`; `docs/poc-deploy-runbook.md`.
- **Legacy:** `../moodle-nginx/README.md`; `.github/workflows/build.yml`, `scheduled-rebuild.yml`, `cleanup.yml`;
  `openshift/scripts/utils/maintenance-mode.sh`; `config/moodle/enable-maintenance-mode.sh`.
- **Private, not in git:** the prod mojibake runbook and baselines, the Phase 0 raw outputs and security notes, and (later)
  the recovery packages, all under `~/Moodle/private-backups/`.
