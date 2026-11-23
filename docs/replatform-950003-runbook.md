# Runbook: replatform 950003 from moodle-nginx to psa-moodle

> **Status: DRAFT v0.4 for review, 2026-11-23. Nothing in this runbook has been executed** except Phase 0, which was
> read-only (2026-11-18).
> v0.2 answered the first review ([replatform-950003-review.md](replatform-950003-review.md), R1–R12, §0).
> v0.3 added facts from the 2026-11-18 prod mojibake window (§0.1).
> **v0.4 answers the second review** ([replatform-950003-rollback-review.md](replatform-950003-rollback-review.md),
> RB01–RB14). It also adds the Phase 0 findings ([replatform-950003-phase0-findings.md](replatform-950003-phase0-findings.md))
> and records the owner's decisions D1–D3 and O1–O4. §0.2 lists every change.
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

**If you reviewed v0.3,** check first that each of RB01–RB14 is resolved by the sections listed in §0.2. Then check that the
owner's decisions (D1–D3, O1–O4) are applied consistently.

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

**Desk review only.** Do not run anything against any cluster. Ground truth is this repository, `../moodle-nginx` and
`../platform-developer-docs`. Facts taken from live cluster inspection are dated in §5.

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
| **O2** | **GitHub sync's nightly task: leave it in legacy.** The outbound guard disables it on every copy. Phase 1 decides whether to uninstall the plugin in test and prod together. | §5.9, §8.2 |
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

## 1. Summary

| | |
|---|---|
| **What** | Replace moodle-nginx with the psa-moodle Helm chart. **moodle-nginx** is MariaDB Galera ×5, Redis with Sentinel, a Go redis-proxy, a pod-health-monitor, and template/DeploymentConfig deploys driven by GitHub Actions. **psa-moodle** is nginx, PHP-FPM and a cron Deployment, with Valkey and Crunchy Postgres 15 plus pgBackRest. |
| **Where** | The existing namespaces `950003-dev`, `950003-test` and `950003-prod` on Silver. |
| **Why there** | 950003 already has 4 CPU / 32 GiB / 96 GiB per namespace; dev and test fit without any request. The new project set (ad4087 on Gold) cannot run anything without a quota increase. |
| **How** | Install the new stack beside the old one under different names. Data is **copied, never moved**. At cutover, legacy is frozen and both public Routes are repointed. Legacy stays intact, frozen and **running** (in maintenance, cron at 0) for a short bail-out window, and is removed only after sign-off. |
| **Order** | Local → dev → test → prod → decommission. |
| **Platform requests** | **Prod: one temporary request for CPU and storage** (D1), sized from dev Pass A's admitted numbers. Indicatively about **+2 CPU and +25 GiB**, until decommission. Test and dev fit today. |
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
    - switch legacy `config.php` to `moodle_bailout` and restart legacy php and cron (cron stays at 0);
    - purge legacy caches.

    Undo: switch `config.php` back to `moodle` and restart, then drop `moodle_bailout`.
  - **E6** Decommissioning (Phase 5).

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
  - for local and dev copies that don't need SSO, no route to the internet at all.

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
  - a **named recovery set** exists: a pgBackRest backup label or recovery time, plus a matching moodledata archive, with
    checksums;
  - the artifacts are verified by reading them, not by a green Job (RB10);
  - an off-site copy exists, with evidence that it is retrievable;
  - scheduled database and moodledata backups run with retention and failure alerts;
  - a combined database-and-files restore from such a set has been demonstrated in dev with the same tooling, and its
    duration recorded.
- **S13. Fence without the new application.** Every rollback and return can stop the new stack's ingress and writers using
  infrastructure only:
  - point the public Routes at legacy or at a maintenance page;
  - scale the new web, php and cron to 0;
  - set `PostgresCluster.spec.shutdown: true` (the Crunchy-supported shutdown);
  - apply a deny-all NetworkPolicy for the release.

  `maintenance.php` on the new site is used when it works, but is never required (RB03).
- **S14. Restore what was there.** Before each window, the window log records every environment's starting state:
  maintenance mode, cron replicas, every Route's YAML, the health monitor's state and replica counts. Every rollback returns
  to exactly that state. Moving legacy from CLI maintenance to web maintenance (as test may need) happens **behind a Route
  fence**, never through an interval open to everyone (RB06).

## 4. Can we always get back to moodle-nginx?

| Stage | What users reach | Roll back by | Data lost | Rehearsed in |
|---|---|---|---|---|
| Phase 0–1 (local only) | Legacy | Nothing to undo | None | n/a |
| Legacy automation paused (E4) | Legacy | Re-enable the workflow; scale the monitor to 1 | None | Dev 2.0 |
| New stack installed beside legacy | Legacy | `helm uninstall psa-moodle`, then delete its listed PVCs and kept Secrets | None | Dev Pass A |
| Legacy frozen (CP1) | Legacy, in CLI maintenance | §13.4, ending in the recorded state (S14) | None | Dev Pass B |
| New site checked on temporary host (CP2) | Legacy, in CLI maintenance | Fence the new stack (S13); then as CP1 | None | Dev Pass B, including new PHP down and Postgres down |
| Routes switched, new site in maintenance (CP3) | New, admins only | Routes back with saved patches; then as CP2 | None | Dev Pass B |
| **Commit point**: new site open (bail-out window) | New | **Second migration** (§14): its own window, checks and commit point | Normally none, but **not guaranteed**: unique-key conflicts (RB08) and ELM deliveries need reconciliation | Dev Pass B, including a failed import, out-of-scope SQL, a failed validation and an abandoned return |
| Return abandoned before legacy reopens | New, resumed | §14 "Abandon and resume" | None | Dev Pass B |
| Last resort | Legacy, on the frozen database | Point legacy at the frozen `moodle` | Everything since reopening; ELM reconciled | Dev Pass B |
| After decommission | New | Restore from backups only | n/a | n/a |

During a bail-out window, legacy stays frozen and **running**. Galera is untouched. Redis, Sentinel, redis-proxy, php and web
run (D1). Legacy cron is at 0, and the site is in CLI maintenance.

## 5. Known facts (re-verify the live ones at the start of each phase)

### 5.1 Versions and plugins (live, 2026-11-17 and 2026-11-18)
- **Prod** is Moodle `4.5.11+ (Build: 20260525)`, version `2024100711.04`. **Test** is Build 20260519, version `2024100711.03`.
  Both have `backup_version` `2024100700`. Both run MariaDB 10.6.20.
- All 455 plugin versions are identical in prod and test.
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
  - `secret/` (Moodle's encryption key lives in `secret/key` unless configured elsewhere);
  - `antivirus_quarantine/` and `.quarantine-20260826T190745Z/`;
  - `muc/config.php`, Moodle's cache-store configuration. It points at the **legacy Redis** and is never copied.

  §8.3 says how each item is handled.
- In legacy, `cachedir` and `tempdir` live under `/var/shared`, and `filecache` and `localrequestdir` on a RAM disk.
- `filedir` is content-addressed: each file's name is the SHA-1 of its content. It is append-only in normal operation.
- Legacy cron also writes a daily `moodledata` `.tar.gz` to `/tmp/file-backups/moodledata` and **keeps only the newest**. It
  is not a retained pre-cutover copy (RB09).

### 5.4 Quota and capacity (live, 2026-11-18)
Figures are **requests against quota**, not utilization. Long-running compute:

| Namespace | CPU free | Memory free | Storage free (aggregate) |
|---|---|---|---|
| Dev | 2.670 of 4 | 28.40 of 32 GiB | **28.66** of 96 GiB |
| Test | 2.625 of 4 | 26.53 of 32 GiB | **18.90** of 96 GiB |
| Prod | **1.025** of 4 | 26.53 of 32 GiB | **2.90** of 96 GiB |
| Tools | 2.000 of 2 | 8.00 of 8 GiB | 18.00 of 64 GiB |

- **The binding storage limit is the aggregate `storage-quota`.** Each storage class also has its own quota (for example
  96 GiB of `netapp-block-standard`, unused), but the aggregate caps them all. Legacy uses only `netapp-file-standard` and
  `netapp-file-backup`.
- **Time-bound pods have their own quota** (`compute-time-bound-quota`, 4 CPU / 32 GiB per namespace, unused). Pods with an
  `activeDeadlineSeconds`, such as backup Jobs, count there and not against long-running CPU.
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
- **D1 request (indicative, finalised from Pass A):** prod **+2 CPU and +25 GiB**, from the start of prod coexistence until
  decommission. Storage covers referenced moodledata (about 3 GiB plus growth), Postgres data and WAL, the pgBackRest
  repository, Valkey and headroom. Test needs about 1–1.5 CPU and 11 GiB, which fit.
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
  and automatic Moodle and OpenShift maintenance. `MANUAL_MODE=true` in dev and prod; **`false` in test** (Q18). **Its only
  alert channel is `ROCKET_CHAT_WEBHOOK`. Rocket.Chat is discontinued, so nobody receives its alerts.**
- **Prod cache topology** (RB04):

  | Controller | Replicas | Notes |
  |---|---|---|
  | `statefulset/redis-node` | 5 | Each pod has `redis` and `sentinel` containers; data and Sentinel state on `emptyDir`; no readiness or liveness probes |
  | `deployment/redis-proxy` | 5 | Readiness checks the master `ROLE` |
  | `deployment/php` | 3 | No probes |
  | `deployment/web` | 3 | No probes |
  | `deployment/cron` | 1 | Also runs the daily moodledata archive loop |

  **There are no HPAs** in any legacy namespace. With D1 none of these is stopped during the migration.
- **Legacy images:**
  - php and cron run `*-security-patch` images from the internal registry, by digest;
  - redis-proxy comes from Artifactory, by digest;
  - **web is a mutable tag** on Artifactory's mirror of `nginxinc/nginx-unprivileged:1-alpine-slim`. Upstream stopped
    publishing that repository at 1.30.6 / 1.31.7, so legacy web gets no further nginx fixes. That is being handled
    separately in moodle-nginx.

  The code is on the `moodle-app-data` PVC, mounted at `/var/www/html`, and `config.php` is a `subPath` ConfigMap mount, so
  a change needs a pod restart. That is why S8 matters.
- **Legacy dev is currently broken.** Galera is at 4 of 5 nodes, and both of its Routes point at `maintenance-message`.
  Pass B needs a healthy legacy dev (Q17).
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
| C7 | `backup.restoreRehearsal` creates a temporary Postgres cluster | Needs storage headroom |
| C8 | The pgBackRest repository is on `netapp-block-standard`, and there is no moodledata backup suitable for file storage | S12 needs an off-site copy and verifiable file backups; `netapp-file-standard` does not support snapshots |
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
- **`local_psaelmsync` settings** (the guard's override list): `apiurl`, `completion_apiurl` (prod
  `analytics-api.psa.gov.bc.ca`, test `analytics-testapi.psa.gov.bc.ca`), `apitoken`, `completion_apitoken`, `enabled`,
  `notificationemails`, `notificationhours`, `datefilterminutes`, `ignorecourseids`, `last_record_enrol_id` and `version`.
  Test also has `dashboardlink`.
- **`local_githubsync` is unused** (owner), but its `sync_courses` task is enabled and runs nightly in prod and test; its
  webhook secret is empty. **O2:** leave it in legacy; the guard disables it on copies.
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
- **Test has been in web maintenance since 2026-11-17** (approved until the week of 2026-11-23). Its window records whatever
  state it is in at T0 (S14).

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

## 6. Open questions for the owner

| ID | Question | Why it matters | Default if unanswered |
|---|---|---|---|
| Q1 | Who owns `learning.gww.gov.bc.ca` (DNS and certificate renewal)? *Test's only hostname is `moodle-950003-test.apps.silver.devops.gov.bc.ca` (Phase 0).* | Certificates must survive the Route switch | Patch the existing Route objects in place; never delete or recreate them |
| Q2 | Who can change the "BC Government Login" redirect URIs? Does anything need `disablelogintoken`? | Login must work the minute the Routes move | Keep the same hostnames; keep `disablelogintoken` until we know |
| Q3 | Is the ELM endpoint IP-allowlisted? Can ELM tell us about duplicates or test traffic? | Outbound safety, and the first post-reopening check | Treat any POST from a copy as an incident |
| Q4 | *Answered: GitHub sync is unused* (O2: its task stays in legacy; disabled on copies) | | |
| Q5 | Do course developers use the tag-based migration script, or move `.mbz` files by hand? | The script breaks after the replatform | Assume manual; tell the developers |
| Q6 | *Answered by Phase 0: only Moodle mobile app tokens; no other database accounts* | | |
| Q7 | Who must be told about downtime? Is there a change-approval process? | Comms and approvals | The owner decides each time |
| Q8 | *Answered by Phase 0: the custom webroot scripts are unused; not carried over* | | |
| Q9 | *Answered (D2): bail-out windows are 3 business days for test and 5 for prod; the owner makes each go/no-go call* | | |
| Q10 | Do the `bht_*` and ad-hoc `local_psaelmsync_logs_*` tables, and the trigger's log table, need keeping beyond the archived dumps? | They are not migrated | The archived dumps are enough |
| Q11 | Where does the off-site copy of the new stack's backups go (S12)? | Platform best practice; C8 | `netapp-file-backup`, which OCIO backs up daily, with retrieval evidence |
| Q12 | Who approves the GitHub changes (disabling `build.yml`; environment protection)? | E4 | The owner. Default branch is `main` |
| Q13 | *Answered by Phase 0: `artifacts.developer.gov.bc.ca/m950-learning`* | | |
| Q14 | Who receives alerts, and who is on call? *Legacy's alerts go only to the discontinued Rocket.Chat.* | Monitoring; S12 failure alerts | The owner, by email, until a channel is chosen |
| Q15 | Are there events to avoid when choosing windows (cohort starts, deadlines)? | Choosing windows | Ask before each window |
| Q16 | Is copying production personal data to the owner's encrypted laptop acceptable under PSA policy for the migration pipeline? | §13 uses a local pipeline | It was done on 2026-08-26, 2026-11-17 and 2026-11-18; confirm |
| Q17 | Legacy dev is broken (Galera 4/5, Routes on the maintenance page). Repair it in dev? | Pass B needs a healthy legacy source; S8 needs a restart proof | Repair legacy dev as its own approved dev-only step, after E4 |
| Q18 | Switch test's health monitor to `MANUAL_MODE=true` now? | It can scale test's Galera to 0 by itself | *Deferred on 2026-11-18, when the replatform looked days away. It is now weeks away, so this is **recommended again** as one approved change to test.* |
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
- **C2:** add `install.enabled` (default `true`). Migrated installs set it to `false`.
- **C3:** add `cron.enabled`, so cron runs 0 or 1 replicas.
- **C4:** scope every NetworkPolicy to release selector labels; no `podSelector: {}` anywhere.
- **C5:** add `moodle.outbound: off | on` (default `off`), which sets `MOODLE_OUTBOUND` for php and cron (§8.2).
- **C6:** add `values-950003-{dev,test,prod}.yaml` with:
  - temporary hostnames;
  - the image home and the per-environment image digest (C10);
  - sizes that fit the Phase 0 numbers, with `maxSurge` set so a rollout fits;
  - **HPAs set to min = max** (or disabled) in every migration state (RB04);
  - `restoreRehearsal` off until storage headroom is confirmed (C7);
  - alert recipients (Q14).
- **C8, C16:** backups that S12 can rely on (RB10):
  - pgBackRest with an off-site copy (Q11);
  - a moodledata backup suited to **file** storage: an archive or rsync to `netapp-file-backup` with checksums, not snapshots;
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
- **Fencing (S13):** a values switch `fence.enabled` renders a deny-all NetworkPolicy for the release's pods. The Crunchy
  shutdown (`spec.shutdown`) and start-up are documented and scripted (`ops/replatform/fence-new.sh`).
- **Route:** the chart's Route only ever carries the temporary hostname. **The public Routes stay legacy objects** until
  Phase 5.
- **Validation:** `helm lint`, `helm template` and `ops/replatform/check-collisions.sh` (read-only; normalises whitespace).

### 8.2 Image changes
- **Exact code (C10, S7).** Build one image per legacy build: **test** at `2024100711.03` (Build 20260519) and **prod** at
  `2024100711.04` (Build 20260525). Every add-on, including `report_allbackups`, `local_githubsync` (O2) and the theme, is at
  the commit that matches what legacy runs.
- **Prove it.** Compare checksums of the image's code tree with the legacy pod's `/var/www/html`, excluding `config.php` and
  the custom webroot files, which are not carried over (Q8). Every add-on's `version.php` must **equal** `config_plugins` in
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
  - the same treatment for `local_githubsync`;
  - `$CFG->scheduled_tasks` disables the `local_psaelmsync` and `local_githubsync` tasks. Verify the 4.5 syntax.
  - `ops/replatform/check-outbound-guard.php` prints the effective values and runs at every checkpoint.
- **Admins on a guarded copy** must not mark real courses complete. Acceptance uses **synthetic** records (§15, RB11).
- Decide each legacy setting in §5.11 and record the decision in §16.
- A migrated site gets its own Valkey cache configuration; `muc/config.php` is never copied.

### 8.3 Migration and recovery tooling (in `ops/replatform/`; reviewed; deleted after Phase 5)
**Forward**
- `migrate-config.php`: the source-side `config.php` for `tool_dbtransfer` (MariaDB, prefix `''`, a scratch dataroot).
- `local-pipeline.sh`:
  1. Restore the dump into MariaDB 10.6.20.
  2. Run `check_database_schema.php`; expect only the §5.2 items.
  3. In the local copy only, drop the reviewed extra tables **and the trigger** (O4).
  4. **Stop if any version differs** from the image (S7).
  5. Run `migrate.php --dbtype=pgsql --prefix=mdl_ …` with the C14 runtime.
  6. `pg_dump -Fc`.
- `compare-content.sh` (R12): per-row and per-table SHA-256 over all column types, with the prefix mapped and binary columns
  normalised to UTF-8 text. `expected-differences.md` lists each accepted difference:
  - `log_display` (rebuilt by `tool_dbtransfer`);
  - `search_simpledb_index` (rebuilt on the target with `search/cli/indexer.php --reindex`, never compared);
  - the dropped tables and trigger.

  Any difference not on the list is a no-go.
- **moodledata copy (O1):** `referenced-files.sql` lists the distinct `contenthash` values in `files` (excluding `.`).
  `moodledata-copy-job.yaml` mounts the legacy PVC **read-only** and copies `filedir` with `rsync --files-from=<that list>`.
  Durable dataroot items (RB07) go per `dataroot-inventory.md`:
  - `lang/` is copied;
  - `secret/` is copied, so values encrypted with Moodle's key stay readable;
  - quarantine folders, `muc/`, caches, sessions, temp, lock and `trashdir` are not copied.
- `check-filedir`: every referenced `contenthash` exists in the target with the right size, and its SHA-1 equals its name.
  The known missing files (prod 3, test 9) are listed in `expected-differences.md`.

**Safety and state**
- `state-capture.sh` / `state-restore.sh` (S14, RB06): record maintenance mode, cron replicas, all Route YAML, the health
  monitor and replica counts per namespace, and restore exactly that. The output is private (S9).
- `fence-new.sh` / `unfence-new.sh` (S13, RB03): the infrastructure-only fence and its reverse:
  - Routes to the fence target;
  - new web, php and cron to 0;
  - the Crunchy shutdown;
  - the deny-all policy.

  Neither script needs the new application to respond.
- `fence-target`: a static maintenance page the public Routes can point at (legacy `maintenance-message`, or the chart's own
  page). The choice is decided and rehearsed in Pass B.
- `admin-check-route.yaml`: a temporary Route to legacy web with `haproxy.router.openshift.io/ip_whitelist` set to the
  operator's address. Admins use it to validate legacy while the public Routes stay fenced (§13.4, §14.7).
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
- `bailout-switch.sh` / `bailout-unswitch.sh`: patch the legacy `config.php` ConfigMap's `$CFG->dbname` to
  `moodle_bailout` (or back to `moodle`). Then restart legacy php and cron, keeping cron at 0, and wait until ready. The
  saved pre-switch ConfigMap is the undo.
- `unique-conflicts.md`: how to read and resolve a unique-key failure in the reverse conversion (RB08). Every resolution is
  an owner decision.
- `quiescence-pg.sql` (RB05): a fresh `pg_stat_activity` read, checked against an allowlist of our management sessions.
  Write counters are reported as supporting evidence only.
- **Removed in v0.4:** `bailout-swap.sql` / `bailout-unswap.sql` (RB01).

### 8.4 Full local rehearsal
Use the **final post-fix prod dump**, which includes the trigger, and the test dump. The local stack runs on a Podman network
created with `--internal`, so it has no route to the internet.
1. Restore and run the schema check. Expect **only** the §5.2 items. Drop the extra tables and the trigger in the copy.
2. Run `tool_dbtransfer` into Postgres (C14 runtime) and time it. Run `compare-content.sh`: only the expected differences.
3. Boot psa-moodle locally against the Postgres copy with the referenced moodledata. Check:
   - `admin/index.php` shows **no pending upgrade**;
   - the environment check passes;
   - the site starts in maintenance;
   - pages work.
4. **Guard test (R2):** with the guard on, complete a **synthetic** course as a synthetic user. Confirm the ELM POST went to
   the dead address and nothing else, and that no email left. Record the cleanup: delete the synthetic records, or reload the
   baseline.
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
7. Write the measured timings into §13.

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
  - **Repair legacy dev (Q17)** as its own approved dev-only step: Galera 5/5, Routes back on `web`.
  - **Recovery package and restart proof (S8, RB09):** build the package for dev. From it alone, with the old pipeline
    untouched, start fresh legacy php, web and cron pods (delete one pod of each). Prove the site works. Repeat after
    draining a node, if the platform allows it.
  - **Egress proof (C15):** with `externalEgress=off`, show the application cannot reach the internet while backup checks
    still reach the Kubernetes API.
- **Pass A: coexistence with an empty install.**
  - `helm install psa-moodle` with `install.enabled=true`, the temporary host, `outbound=off` and `externalEgress=off`.
  - Verify the legacy object list and the legacy site are **unchanged**; compare before and after.
  - Record **admitted** requests of every pod, including sidecars, rollout surge and backup Jobs (time-bound quota). These
    numbers finalise the D1 request (§5.4).
  - Record the actual Postgres collation (RB08).
  - Exercise:
    - a pgBackRest backup;
    - a restore drill;
    - pod-kill and PDB behaviour;
    - alerts;
    - **the fence and unfence**: Crunchy `spec.shutdown` and restart, with quota measured in each state (RB04).
  - **Undo:** `helm uninstall psa-moodle`; then delete the listed `psa-moodle-*` PVCs, the PostgresCluster and the kept
    Secrets.
- **Pass B: dress rehearsal of the cutover (§13) and the return (§14).** Legacy dev is the source, and its Routes play the
  public Routes. Record the starting state (S14) first. Each run must include:
  - a rollback at **every** checkpoint (CP1, CP2, CP3), ending in exactly the recorded state;
  - a rollback with **new PHP down**, with **new Postgres down**, and after a **failed Helm rollout** (S13; the old site's
    return must not need the new site);
  - one complete forward run to reopening, with the commit point recorded before it happens (S11);
  - a return (§14) that includes:
    - an **import interrupted halfway**, recovered by dropping `moodle_bailout`, with the frozen `moodle` proven untouched;
    - an **out-of-scope SQL statement denied**;
    - a **validation failure after the handover**, undone with `bailout-unswitch.sh`, with the new site resumed and no work
      lost;
    - a complete return to legacy dev, ending with legacy reopened by its own approval;
  - **representative new writes** before the return: uploads, edits and deletes, a course restore, a quiz attempt,
    synthetic completions, accent-distinct tags, and fresh IDs (RB08, RB11);
  - a check that legacy serves the CLI maintenance page.

  Time everything. From the measured durations, set a **latest-abort time** for each window. **Do this twice cleanly.**
- **Pass C: production-scale acceptance.**
  - Load the post-fix prod database (through the local pipeline) and the **full referenced prod file set** (about 3 GiB) into
    the new dev stack, with `outbound=off` and `externalEgress=off`.
  - Run §15 and compare page timings with legacy prod.
  - Demonstrate the S12 combined restore from a **named recovery set**: retrieve it independently, restore it, boot Moodle,
    and run `check-filedir` and login. Include an upload and a deletion between backup times. Record the time taken and the
    latest recoverable point.
  - Run a full return at this size and record its duration and storage use (RB07).
- **Soak for one week:** backups and their verification, alerts, and cron with the guard on and no internet.
- **Operator checklist:** a one-page checklist per window, kept beside this runbook, so a tired operator doesn't have to
  reconcile §11, §13 and §14.

**Exit gate:** two clean Pass B runs as above; measured window and return durations the owner accepts; the S12 restore
demonstrated; and sign-off from reviewers and the owner.

## 10. Phase 3: 950003-test (production-grade)

- **Before:**
  - tell the course developers about the window and the freeze on site-level administration (Q20); they already know
    automated course backups haven't run since May (Q21);
  - agree the window;
  - take fresh verified backups of the database **and** moodledata;
  - build the test recovery package (S8);
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
- **Submit the D1 temporary quota request early:** CPU and storage, using Pass A's admitted numbers plus surge, the wording
  of platform docs Example 3, and a duration lasting until decommission.
- **ELM contact (Q19):** the owner. Before the window, confirm with ELM how received completions can be checked.
- **Tell the admins** that site-level administration is frozen for the bail-out window (Q20).
- **Tell learners** and agree the window.
- **E4 in prod:** scale prod's pod-health-monitor to 0 before the new stack is installed.
- Build the prod recovery package (S8).
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
9. Update `README.md`, `CLAUDE.md` and this runbook.

## 13. The cutover window (used in dev Pass B, test and prod)

The timings are placeholders until Phase 1 measures them. Every step is approved in advance as a set, and each checkpoint
(CP) is an explicit go/no-go call by the owner. Throughout, until §13.3: **new cron is 0, the outbound guard is on.**

### 13.1 Freeze legacy (R3)
| T | Step | Verify | Undo |
|---|---|---|---|
| T−7d | New stack deployed (`install=false`, `outbound=off`, `cron=off`, temporary host); referenced files pre-copied | Collision check clean; legacy unchanged | `helm uninstall` and delete its PVCs |
| T−1d | Backups verified; recovery package current; comms sent; quota recomputed; laptop on power and wired, sleep disabled | n/a | n/a |
| T0 | **`state-capture.sh`** (S14); note the latest-abort time | Saved privately | n/a |
| T0 | **E1:** `php admin/cli/maintenance.php --enable` in one legacy php pod | Public URLs return the maintenance page to anonymous users **and** an admin session; a web-service call is refused | Restore the captured state (S14) |
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
| T+? | Admin checks through the **temporary** Route, with wwwroot on the temporary host | Every response carries `X-PSA-Stack: psa-moodle` | n/a |
| **CP2** | **Go/no-go: does the new site work for admins?** | | §13.4 |
| T+? | Generate exact Route undo patches from the captured YAML. `helm upgrade` wwwroot = public hostname (still maintenance, cron 0, guard on) | Pods ready | `helm rollback` |
| T+? | **E3:** patch **both** prod Routes: `spec.to.name` → `psa-moodle-web`, `spec.port.targetPort` → `http`, timeout annotation `900s`. Certificates untouched | Both hostnames return `X-PSA-Stack: psa-moodle`; the custom certificate is still served | Undo patches (Routes first), then `helm rollback` |
| T+? | Admin checks through both public hostnames, including **SSO login**; §15 spot checks with **synthetic** records only | | |
| **CP3** | **Go/no-go: open the site?** | | Routes back, then §13.4. **No data lost.** |

### 13.3 The commit point (S11, S12, RB11)
| T | Step | Verify |
|---|---|---|
| T+? | **S12 recovery set:** named pgBackRest backup after the restore, plus the matching moodledata archive and checksums; artifacts read back; off-site copy present with retrieval evidence | Each item recorded in the window log |
| T+? | **Record the commit point** in the window log: time, the exact command about to run, and the **ELM baseline** (the latest `local_psaelmsync` log id and time on the new site). From the next step on, going back means §14 | Logged before continuing |
| T+? | `helm upgrade` with `outbound=on` and `cron=on` (this also renders the SMTP egress policy, C9). **This is the commit point, even if the rollout fails part-way** | `check-outbound-guard.php` shows real values; a cron run succeeds |
| T+? | `php admin/cli/maintenance.php --disable` on the new site; announce | Learners and authors can log in; a test email arrives; the first real ELM completion appears in the plugin's log |

### 13.4 Reverse sequence (any rollback before the commit point)
1. **Fence the new stack (S13):**
   - if the Routes were switched, apply the saved undo patches first, or point the Routes at the fence target;
   - scale new web, php and cron to 0;
   - if needed, `spec.shutdown: true` for Postgres.

   Use `maintenance.php --enable` on the new site only if it responds. Verify that no hostname returns `X-PSA-Stack`.
2. **Legacy dependencies are already running (D1).** Confirm Sentinel reports a master and quorum, redis-proxy is ready,
   and legacy php and web are ready.
3. **Validate legacy before anyone else returns (RB02):** keep the public Routes on the fence target or on legacy in CLI
   maintenance. If admin checks are needed, use `admin-check-route.yaml` (an IP-allowlisted Route) after moving legacy to web
   maintenance **behind the fence** (S14).
4. **Separate approval: restore the captured starting state (S14).** That covers maintenance mode (prod: off; test: whatever
   was recorded, possibly web maintenance), cron replicas and both Routes exactly as captured. Remove the admin-check Route.
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
- The recovery package is current (S8); `state-capture.sh` has run.

### 14.1 Stop the new site (fence first, RB03, RB05)
1. **Fence (S13):** Routes to the fence target; new cron 0; `helm upgrade` with `outbound=off`; `maintenance.php --enable`
   on the new site if it responds.
2. **Drain:** running tasks finish, or are stopped by the cron scale-down; requests have drained.
3. **Quiescence:** `quiescence-pg.sql` shows only allowlisted management sessions. Write statistics are supporting evidence
   only.
4. **ELM end-mark:** record the last `local_psaelmsync` log id and time. The ELM deliveries to reconcile lie between the
   §13.3 baseline and this mark.

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

### 14.6 Handover (E5, D3)
Run `bailout-switch.sh`: legacy `config.php` → `moodle_bailout`; restart legacy php and cron (cron stays 0). Legacy remains in
CLI maintenance, and the public Routes stay on the fence target.
**Undo:** `bailout-unswitch.sh` (back to the frozen `moodle`, restart).

### 14.7 Caches and validation (RB02)
Redis is already running (D1).
1. `purge_caches.php` on legacy.
2. Move legacy from CLI to web maintenance behind the fence (S14).
3. Validate through `admin-check-route.yaml` only. Check:
   - no pending upgrade, and versions equal;
   - records created on the new stack are present, files included;
   - the local admin login and SSO;
   - a controlled synthetic record gets a fresh ID.

Legacy has **no** outbound guard, so nobody triggers completions during these checks.

### 14.8 Go/no-go 2 and separate approval: reopen legacy
Point the Routes at legacy `web`, set maintenance and cron to their captured states, remove the admin-check Route, and
announce. **This is the return's commit point.** After it, going back to the new stack is another migration.

### 14.9 ELM reconciliation (RB11)
With the ELM contact, compare the completions the new site sent (between the baseline and the end-mark) with ELM's records.
Handle duplicates and gaps as agreed. Legacy does not replay anything automatically. Record the outcome.

### Abandon and resume (before 14.8, RB03)
The return can be abandoned at any point before 14.8, losing no work, because no writes were accepted anywhere after the
fence:
1. if 14.6 ran, `bailout-unswitch.sh`;
2. `DROP DATABASE moodle_bailout` and drop the import account;
3. `unfence-new.sh`: Postgres up, scale up, `outbound=on`, cron on;
4. `maintenance.php --disable` on the new site; Routes back to the new stack.

### Last resort (owner only)
If the new site cannot resume and the return cannot complete:
- legacy goes back on the frozen `moodle` (`bailout-unswitch.sh` if needed), losing all work since reopening;
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
- **Login:** SSO ("BC Government Login") on the public hostnames and the local admin account.
- **Courses:** course pages, images and files; H5P (`mod_hvp` and core); lessons, books and quizzes, including an attempt;
  grades; search; reports, including `report_allbackups`; document conversion (unoconv, Ghostscript).
- **Completion:** only on **synthetic** courses and users, with the guard on, and with the recorded cleanup applied afterwards
  (RB11).
- **Course flow:** back up a course (`.mbz`) and restore it across environments.
- **Before opening (S12):** a named recovery set with artifacts read back, checksums, off-site retrieval evidence, scheduled
  backups with alerts, and the combined restore demonstrated in dev, with its duration.
- **After opening:**
  - a test email is delivered (C9);
  - the first real ELM completion POST succeeds, and ELM confirms receipt (Q3, Q19);
  - `task_log` shows tasks succeeding, and ad hoc tasks drain;
  - no new errors in the PHP and cron logs.

  There is **no** row-count comparison after opening.
- **Platform:** the integrity CronJob passes; alerts reach the recipients (Q14); the PDBs and HPA behave as expected.
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
| 2026-11-18 | Test stays in web maintenance until the week of 2026-11-23 or its replatform; communicated and approved | Owner |
| 2026-11-18 | Q18 deferred (re-recommended in v0.4, since the timeline is now weeks) | Owner |
| 2026-11-20 | psa-moodle web image on nginx 1.30.7 (`docker.io/nginx/nginx-unprivileged`, by digest); the a58ce1-dev PoC was patched by hand | Owner |
| 2026-11-23 | Accept second-review findings RB01–RB14 into v0.4 | Owner |
| 2026-11-23 | **D1** One temporary prod request for CPU and storage; legacy dependencies stay running through the bail-out window | Owner |
| 2026-11-23 | **D2** Firm rollback before the commit point; a second migration after it; bail-out windows of 3 (test) and 5 (prod) business days | Owner |
| 2026-11-23 | **D3** Return by switching legacy `config.php` to a verified `moodle_bailout`; no `RENAME TABLE` | Owner |
| 2026-11-23 | **O1** Copy referenced files only; archive the unreferenced set before decommission; investigate only on report | Owner |
| 2026-11-23 | **O2** Leave GitHub sync's task in legacy; the guard disables it on copies; Phase 1 decides on uninstalling | Owner |
| 2026-11-23 | **O3** Test's automated course backups (failing since 2026-05-20): leave to the replatform; tell the developers | Owner |
| 2026-11-23 | **O4** Drop `trg_log_completion_criteria_delete` on the new stack | Owner |
| 2026-11-23 | **Q19** The owner is the ELM contact; **Q20** freeze site-level administration during bail-out windows; **Q21** course developers told about test's automated backups | Owner |

**Phase 0 findings (2026-11-18):** see [replatform-950003-phase0-findings.md](replatform-950003-phase0-findings.md).
The facts that change the plan are folded into §5 and §6.

## 17. References
- **Reviews:** [replatform-950003-review.md](replatform-950003-review.md) (v0.1, R1–R12) and
  [replatform-950003-rollback-review.md](replatform-950003-rollback-review.md) (v0.3, RB01–RB14).
- **Phase 0:** [replatform-950003-phase0-findings.md](replatform-950003-phase0-findings.md)
- **Moodle:** [Administration via command line, Maintenance mode (4.5)](https://docs.moodle.org/405/en/Administration_via_command_line#Maintenance_mode)
- **MariaDB:** [RENAME TABLE](https://mariadb.com/docs/server/reference/sql-statements/data-definition/rename-table) (tables
  with triggers can't change database);
  [mariadb-dump options](https://mariadb.com/docs/server/clients-and-utilities/backup-restore-and-import-clients/mariadb-dump)
  (`--databases` adds `CREATE DATABASE` and `USE`)
- **PostgreSQL 15:** [statistics](https://www.postgresql.org/docs/15/monitoring-stats.html),
  [collation](https://www.postgresql.org/docs/15/collation.html)
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
