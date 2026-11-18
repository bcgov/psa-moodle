# Runbook: replatform 950003 from moodle-nginx to psa-moodle

> **Status: DRAFT v0.2 for review, 2026-11-18. Nothing in this runbook has been executed.**
> v0.2 incorporates the independent review of v0.1 ([replatform-950003-review.md](replatform-950003-review.md),
> findings R1–R12). It accepts all twelve findings and its additional corrections. §0 shows where each one is addressed.
> It supersedes the "request a new project set" direction in `README.md` (Current direction) and
> `docs/quota-request.md`. The new plan is to replatform **inside** the existing 950003 namespaces
> on Silver, using their existing quota, then release ad4087 (Gold) and retire a58ce1.

---

## How to review this document (reviewers start here)

This is a plan to replace the live Moodle stack in OpenShift project set **950003** (BC Gov Silver).
The service owner is cautious and wants a plan that cannot strand them.

**The core promise is this.**
- Until the new production stack is opened to learners, every step is reversible with zero data loss.
- Opening it is a single, deliberate **commit point** (S11). Before that point, no copy of real data has been able to email
  anyone or send anything to ELM.
- After the commit point, a rehearsed bail-out path back to moodle-nginx exists for a fixed, agreed window. The frozen legacy
  database is never overwritten, so the bail-out can itself fail without stranding us.

**Please try to break this promise.**

**If you reviewed v0.1:** check first that each of R1–R12 is actually resolved by the sections listed in §0, and that the
fixes have not introduced new gaps.

Look especially for:

1. **Writes to the legacy data.** Any step that writes to the 950003-test or 950003-prod legacy database or
   moodledata, other than the exceptions allowed in §3.
2. **Shared-namespace interference.** Any way the new stack, running beside legacy in the same namespace, could change, delete, select or
   take traffic from a legacy object, or the reverse. Consider name collisions, label selectors, NetworkPolicies (including the
   union with existing namespace-wide policies), Services, Routes, quota exhaustion, and legacy automation.
3. **Outbound leaks.** Any way a copy of real data could reach the outside world before the commit point:
   email, the ELM completion POST, ELM/CData reads, the GitHub sync, web services or SSO.
4. **Rollback gaps.** A step without an undo; an undo that is never rehearsed; an undo that depends on
   the legacy deploy pipeline (no deploy has completed since May 2026); or an undo that does not fit in quota.
5. **Quota.** Arithmetic that doesn't add up. Include operator-generated sidecars, rollout surge and backup Jobs.
6. **Platform conflicts.** Anything that contradicts the BC Gov platform docs (`../platform-developer-docs/src/docs/`).
7. **Moodle migration pitfalls.** For example `tool_dbtransfer` behaviour, the table-prefix change, MUC
   configuration, file paths stored in the database, plugin versions, wwwroot handling, or maintenance-mode semantics.
8. **Stale facts.** Anything in §5 that you think is wrong or out of date.

**How to report.** Use one line per finding:
`ID | severity (blocker / major / minor) | section and step | concrete failure scenario | suggested change`.

**Desk review only.** Do not run anything against any cluster. Ground truth is this repository, `../moodle-nginx` and
`../platform-developer-docs`. Facts taken from live cluster inspection are dated in §5; Phase 0
re-verifies them.

---

## 0. Changes from v0.1

| Finding | What changed | Where |
|---|---|---|
| R1 outbound and cron enabled before CP2 | Cron, email and integrations stay off through CP3. Turning them on **is** the commit point. Every rollback stops the new stack's processing first. | S4, S11, §13.3, §14 step 1 |
| R2 ELM observer POSTs directly | Fail-closed guard in `config.openshift.php`: `forced_plugin_settings` replaces every ELM URL and token, plus `noemailever` and web services off. Local copies run on a Podman network with no internet. Rehearsal proves it with a deliberate course completion. GitHub sync is removed from acceptance (unused). | S4, C5, §8.2, §8.4 step 4 |
| R3 web maintenance doesn't stop all writers | Freeze uses CLI maintenance (`maintenance.php --enable`), drains running tasks, then proves quiescence before the final dump and file copy. The legacy wrapper (`--wait`) is never used. | §5.10, §13.1 |
| R4 reverse import destroyed the frozen baseline | Reverse import goes into a **separate** database (`moodle_bailout`). The frozen `moodle` database is untouched until a verified, one-statement swap that is itself reversible. A failed import is rehearsed. New exception E5. | S1, §14 |
| R5 build alignment | Each environment's new image is pinned to the exact code its legacy side runs (test `.03`, prod `.04`). Plugins are pinned to identical code, not "at least as new". The pipeline never upgrades a copy; it stops on any mismatch. Test is aligned to prod only after both bail-out windows close. | S7, C10, §8.2, §10 |
| R6 reverse scaling and quota | Full forward and reverse scaling sequences, with readiness checks and HPA handling. Quota is sized from admitted pod resources, including Crunchy sidecars, rollout surge and backup Jobs. | §5.4, §11.2, §13.4 |
| R7 wwwroot redirect | CP2 checks run with wwwroot on the temporary host. wwwroot and the Routes switch together afterwards. Every check confirms which stack answered (a response header). | C12, §13.2 |
| R8 two prod Routes | Both prod Routes are switched and undone together. Certificates are preserved; the 900 s timeout is set explicitly; exact undo patches are saved. | §5.7, §13.2 |
| R9 legacy automation touches all Routes | Pausing legacy automation (the `build.yml` workflow and the pod-health-monitor) is mandatory before coexistence in any namespace. Restoration conditions are written down. | E4, §5.5, §9.0 |
| R10 backups before reopening | Scheduled database and moodledata backups, an off-site copy and a demonstrated combined restore are required **before** reopening. | S12, §13.3, §15 |
| R11 SMTP egress for backup Jobs only | New chart change C9: SMTP egress for php and cron, present only when outbound is on. | C9, §8.1 |
| R12 row counts are not proof | Per-table content hashes from frozen baselines, with documented expected differences. Files are checked by SHA-1 against their content-hash names. No 24-hour count comparison. The reverse direction is checked the same way after new writes. | §8.3, §8.4, §15 |
| Additional: maintenance commands | Exact commands per stage; see §5.10. | §5.10 |
| Additional: NetworkPolicy union | Existing namespace-wide allow policies are recorded; no claim of per-component isolation. | §5.8 |
| Owner: GitHub sync unused | Kept disabled on copies; removed from acceptance. | §5.9, §15 |
| Corrections | Prod storage is 93.10 GiB requested, not 95.3. Prod's custom Route has no timeout annotation (router default 30 s). Legacy dev is currently broken. | §5.4, §5.7, §5.5 |

## 1. Summary

| | |
|---|---|
| **What** | Replace moodle-nginx with the psa-moodle Helm chart. **moodle-nginx** is MariaDB Galera ×5, Redis with Sentinel, a Go redis-proxy, a pod-health-monitor, and template/DeploymentConfig deploys driven by GitHub Actions. **psa-moodle** is nginx, PHP-FPM and a cron Deployment, with Valkey and Crunchy Postgres 15 plus pgBackRest. |
| **Where** | The existing namespaces `950003-dev`, `950003-test` and `950003-prod` on Silver. |
| **Why there** | 950003 already has 4 CPU / 32 GiB / 96 GiB per namespace, and dev fits without any request. The new project set (ad4087 on Gold) cannot run anything without a quota increase. |
| **How** | Install the new stack beside the old one under different names. Data is **copied, never moved**. At cutover, legacy is frozen and both public Routes are repointed. Legacy stays intact and frozen for a bail-out window, and is removed only after sign-off. |
| **Order** | Local → dev → test → prod → decommission. |
| **Platform requests** | Prod needs a temporary storage increase for the parallel run (2.90 GiB free today). This is platform docs Example 3, "Temporary quota for a migration". Test may need the same; Phase 0 decides. |
| **Commit point** | Opening the new site (S11): maintenance off, cron and outbound on. Before it, rollback loses nothing. After it, going back needs the rehearsed reverse migration (§14) or loses the new work. |

## 2. Environment roles (`CLAUDE.md` is authoritative)

| Namespace | Users | Treat as |
|---|---|---|
| `950003-prod` | Learners | Production |
| `950003-test` | Course developers and instructional designers, who build courses here | **Production** |
| `950003-dev` | Nobody; ephemeral | The only cluster target for experiments |

## 3. Safety rules

- **S1. Legacy is not modified** until Phase 5, except through these exceptions. Each one is its own approved step with a
  written undo:
  - **E1** Maintenance mode on or off, using the exact commands in §5.10.
  - **E2** Scaling legacy cron, web, php, redis, sentinel or redis-proxy down and back up during a window (§11.2, §13.4).
  - **E3** Repointing the public Routes' backend, timeout annotation and target port (§13.2). Certificates are never changed.
  - **E4** Pausing legacy automation: disabling the `build.yml` workflow in GitHub (all its triggers) and scaling the
    pod-health-monitor to 0. Done before coexistence in each namespace, with restoration conditions (§9.0).
  - **E5** Bail-out writes, during a bail-out only (§14): create and load a separate `moodle_bailout` database in Galera;
    add files to legacy moodledata (add-only, never delete or overwrite); swap the databases with one `RENAME TABLE`
    statement; purge legacy caches.
  - **E6** Decommissioning (Phase 5).

  **Galera is never restarted, scaled or reconfigured before Phase 5.** A full Galera cold start
  is the failure mode behind the May 2026 eight-hour outage.
- **S2. Legacy data is only read,** except through E5. Database dumps use `mariadb-dump --single-transaction`, and moodledata is read through a
  read-only mount.
- **S3. The new stack is additive and identifiable by name.** Everything it creates is named `psa-moodle-*`: the Helm release
  is `psa-moodle`, and Crunchy objects are `psa-moodle-pg-*`. No literal names, and no selector that can match a legacy pod.
- **S4. Real-data copies stay quiet.** Until the commit point (S11), every copy of real data, whether local, dev, test or prod, runs with:
  - the outbound guard on (§8.2): no email, ELM URLs and tokens replaced with a dead local address, web services off;
  - cron off;
  - for local and dev copies that don't need SSO, no route to the internet at all.

  The guard is fail-closed: it is on unless `MOODLE_OUTBOUND=on` is set explicitly.
- **S5. One approved change at a time.** Every cluster change is a numbered step with the exact command, expected result, verification and
  undo, approved by the owner individually. Read-only inspection never needs approval.
- **S6. Test and prod need full preparation:** a fresh verified backup (database **and** moodledata), an agreed window,
  maintenance mode, a go/no-go and a written rollback.
- **S7. Exact code, both directions.** Each environment's new image runs exactly the Moodle core and plugin code its legacy
  side runs (§8.2). No step upgrades a copy, and the pipeline stops on any version mismatch. **No Moodle upgrade on either
  side during a bail-out window**, because the reverse migration needs identical code.
- **S8. Never rely on redeploying legacy.** Legacy CI has failed every deploy since May 2026. Rollback relies on
  legacy *staying deployed*.
- **S9. Personal data stays in owner-only storage.** Dumps, file copies and saved Route YAML (which holds certificate keys)
  go on the encrypted laptop disk, in mode-700 folders with mode-600 files. Never put them in git, chat or shared drives.
- **S10. The stop rule.** If anything unexpected happens: stop, return to the last known-good state, write down what
  happened, and only then continue.
- **S11. The commit point is explicit.** Cron, email, ELM sync and web services come on only when the new site opens, as one
  approved step after CP3 (§13.3). Before any rollback, the new stack's processing is stopped first.
- **S12. No reopening without working backups.** Before the new site opens: a pgBackRest full backup has completed, scheduled
  database and moodledata backups are running with retention and failure alerts, an off-site copy exists, and a combined
  database-and-files restore has been demonstrated (in dev, with the same tooling).

## 4. Can we always get back to moodle-nginx?

| Stage | What users reach | Roll back by | Data lost | Rehearsed in |
|---|---|---|---|---|
| Phase 0–1 (local only) | Legacy | Nothing to undo | None | n/a |
| Legacy automation paused (E4) | Legacy | Re-enable the workflow; scale the monitor to 1 | None | Dev 2.0 |
| New stack installed beside legacy | Legacy | `helm uninstall psa-moodle`, then delete its listed PVCs and kept Secrets | None | Dev pass A |
| Legacy frozen (CP1) | Legacy, in CLI maintenance | Reverse scaling (§13.4), legacy maintenance off | None | Dev pass B |
| New site checked on temporary host (CP2) | Legacy, in CLI maintenance | Scale new stack down; then as CP1 | None | Dev pass B |
| Routes switched, new site in maintenance (CP3) | New, admins only | Routes back with saved patches; then as CP2 | None | Dev pass B |
| **Commit point**: new site open (bail-out window) | New | Reverse migration into `moodle_bailout`, then swap (§14) | None | Dev pass B, including a failed import |
| Reverse migration fails | New | Last resort: Routes back to the untouched frozen legacy database | Everything since reopening | Dev pass B |
| After decommission | New | Restore from backups only | n/a | n/a |

During a bail-out window, legacy stays frozen with its Galera cluster **running and untouched**. Stateless legacy pods may be
scaled to 0; §13.4 is the sequence for bringing them back.

## 5. Known facts (re-verify the live ones in Phase 0)

### 5.1 Versions and plugins (live, 2026-11-17 and 2026-11-18)
- **Prod** is Moodle `4.5.11+ (Build: 20260525)`, version `2024100711.04`. **Test** is Build 20260519, version `2024100711.03`.
  Both have `backup_version` `2024100700`. Both run MariaDB 10.6.20.
- All 455 plugin versions are identical in prod and test.
- The psa-moodle image is built from the **head** of `MOODLE_405_STABLE` and of each plugin's branch
  (`Containerfile.php`, `git clone --depth=1 --branch`), so its exact code is not pinned. It **lacks `report_allbackups`**
  (6 add-ons against prod's 7).
- Prod's PHP and cron were hand-patched on 2026-10-21 with `*-security-patch` images. The psa-moodle image has PHP 8.3.36.

### 5.2 Database (live, 2026-11-17)
- **Prod:** 719 tables (all InnoDB) and 5,250,571 rows. The dump is 99.8 MB gzipped (710 MB of SQL); about 1.16 GB on disk.
- **Test:** 713 tables and 316,427 rows; the dump is 10.1 MB gzipped.
- **Table prefix:** legacy uses `$CFG->prefix = ''`. psa-moodle's `config/moodle/config.openshift.php` uses `'mdl_'`.
- **Tables that are not in Moodle's schema** make `tool_dbtransfer` abort. Its `migrate.php` calls
  `database_mover(..., check_schema=true)`, which rejects extra tables.
  - Both environments: **195 `bht_*` Behat tables.**
  - Prod only: `course_completion_criteria_log` and six `local_psaelmsync_logs_*` copies:
    `_backup`, `_backup_20240522`, `_backup2`, `_bad_restore`, `_copy2` and `_muckedup`.
  - Test only: `local_psaelmsync_enrol`.
- `tool_dbtransfer` rebuilds `log_display` in the target, so that table is an expected difference (§8.3).
- **Verified backups** are in `~/Moodle/private-backups/`: prod at 2026-11-17T00:20Z and test at 2026-11-17T23:10Z.

### 5.3 moodledata
- Prod holds about 9.2 GB. Test's volume is 12 GiB, with 3.6 GiB used.
- In legacy, `cachedir` and `tempdir` live under `/var/shared`, and `filecache` and `localrequestdir` on a RAM disk.
- `muc/config.php` in dataroot holds Moodle's cache-store configuration, which points at the **legacy Redis**. It is never copied.
- `filedir` is content-addressed: each file's name is the SHA-1 of its content. It is append-only in normal operation.

### 5.4 Quota and capacity (live, 2026-11-18)
Each namespace has 4 CPU / 32 GiB / 96 GiB. Figures are **requests against quota**, not utilization.

| Namespace | Storage requested | Storage free | CPU requested | CPU free |
|---|---|---|---|---|
| Dev | 68,958 Mi (67.34 GiB) | **28.66 GiB** | 1.330 | **2.670** |
| Test | 78,948 Mi (77.10 GiB) | **18.90 GiB** | 1.375 | **2.625** |
| Prod | 95,332 Mi (93.10 GiB) | **2.90 GiB** | 2.975 | **1.025** |

- Prod's storage is mostly 5 × 10 GiB Galera PVCs. Of prod's 2.975 CPU, Redis, Sentinel and the proxy request 1.75.
- **Admitted resources are more than the chart's containers.** In the a58ce1 PoC, each Crunchy Postgres pod has three extra
  containers at 50m CPU / 256 Mi each (+150m / +768 Mi per instance), and the pgBackRest repo host has two (+100m / +512 Mi).
  Rollout surge and backup Job pods also count against quota. Sizing uses admitted requests from a rendered and installed
  dev stack, not template sums (step 0.5).
- The psa-moodle PoC used 0.9 CPU / 2.75 GiB / 7 GiB before sidecars. A dev or test profile with real data needs more.
- The **legacy Galera PVCs** must have room for a second copy of the database during a bail-out (§14). Phase 0 measures their
  free space.

### 5.5 Legacy machinery that can interfere
- **`build.yml` is the only legacy workflow that deploys.** Its triggers are the weekly schedule (Saturday 03:00 UTC, cron
  `0 3 * * 6`), pushes and pull requests to `950003-dev`, `950003-test` or `950003-prod`, and manual dispatch. The other
  workflows are called by it (`workflow_call`), or don't touch the cluster (`notify.yml`, `security-comprehensive.yml`).
  Disabling the `build.yml` workflow stops all four triggers. Queued or running runs must also be cancelled.
- The scheduled run deploys to dev, fails every week, and leaves dev on the maintenance page.
- **Cleanup deletes by fixed name.** `cleanup.yml` deletes the Service, Deployment, ConfigMap, PVC, Route and Secret by
  name. A new object whose name matches a legacy name could be deleted, or could break the legacy deploy.
- **Legacy maintenance scripts patch every Route in the namespace.** `openshift/scripts/utils/maintenance-mode.sh` (lines 98–100)
  and `remove-maintenance-message.sh` loop over all Routes, so `psa-moodle-*` names don't protect the new Routes. "Remove
  maintenance" points every Route back at legacy `web`.
- **The pod-health-monitor** (2026-11-18). In all three namespaces: `GALERA_AUTO_HEAL_ENABLE_FAILSAFE=true`,
  `FAILSAFE_SCALE_REPLICAS=0`, `AUTO_ENABLE_MOODLE_MAINTENANCE=YES` and `AUTO_ENABLE_OPENSHIFT_MAINTENANCE=YES`.
  `MANUAL_MODE=true` in dev and prod; **`MANUAL_MODE=false` in test**, so test's monitor can scale Galera to 0 and repoint
  Routes by itself. Where its alerts go is unknown (step 0.8).
- **Legacy dev is currently broken.** Galera is at 4 of 5 nodes and its Routes point at the `maintenance-message` service
  (2026-11-18). Pass B needs a healthy legacy dev (Q17).
- **Course flow automation.** `migrate-courses-between-namespaces.sh` moves courses tagged "Testing" or "Production" between namespaces
  by running `oc exec` in the legacy pods. It breaks after the replatform (Q5).

### 5.6 Chart and image changes required before deploying into 950003
| # | Finding | Why it matters |
|---|---|---|
| C1 | `templates/php-service.yaml` creates a Service with the literal name **`php`**, because nginx hard-codes `fastcgi_pass php:9000` | It collides with legacy `service/php`. Either the install fails, or the two stacks fight over the name. |
| C2 | `templates/job-install.yaml` runs `install_database.php` on every `helm install` | A migrated site needs an **empty** database for `tool_dbtransfer`, so we need a value that turns this off |
| C3 | `templates/cron-deployment.yaml` always runs one replica | S4 and S11 require cron off until the commit point |
| C4 | `templates/monitoring.yaml` NetworkPolicy uses `podSelector: {}` | Additive under the platform's default deny, but it opens ports 9187 and 9253 on **legacy** pods to the monitoring namespace. It should select only release pods. |
| C5 | No outbound guard | S4 needs the fail-closed guard in §8.2 |
| C6 | Values, images and hostnames all point at a58ce1 | a58ce1 is being retired |
| C7 | `backup.restoreRehearsal` creates a temporary Postgres cluster | It needs storage headroom that test and prod may not have during the parallel run |
| C8 | The pgBackRest repository is on `netapp-block-standard` | That class is not backed up off-site by OCIO; S12 needs an off-site copy |
| C9 | The SMTP egress policy selects only the backup components (`networkpolicy.yaml`) | Moodle's own email from php and cron would be blocked after reopening |
| C10 | Moodle core and plugins are cloned from branch heads | S7 needs exact, per-environment code |
| C11 | Only the chart's own Route has the 900 s timeout | The legacy public Routes keep 180 s (`moodle-web`) or the 30 s router default (`moodle-custom`) unless the cutover sets it |
| C12 | Nothing identifies which stack served a response | CP2 and CP3 checks must prove the new stack answered (R7) |

### 5.7 Routes and hostnames (live, 2026-11-18)
- **Prod has two Routes, both pointing at legacy `web`:**
  - `moodle-custom`: `learning.gww.gov.bc.ca`, with a **custom certificate**, and no timeout annotation (router default 30 s).
  - `moodle-web`: `moodle-950003-prod.apps.silver.devops.gov.bc.ca`, with `haproxy.router.openshift.io/timeout: 180s`.
- Test's and dev's Routes are listed in step 0.13.
- The new chart's Service port is named `http`; its Route uses `targetPort: http` and `timeout: 900s` (`values.yaml`).

### 5.8 NetworkPolicies (live, 2026-11-18)
- The platform applies a default deny in every namespace; allow policies are **additive**.
- Prod's `allow-all-internal` selects all pods and allows traffic from the prod and tools namespaces. Test's also allows
  traffic from **950003-dev**. Router ingress policies select all pods.
- So the new stack's pods are reachable on any port from those namespaces, whatever the chart's own policies say. The plan does
  not claim per-component isolation. Database and Valkey rely on their authentication. Phase 5 reviews whether these broad
  policies are still needed.

### 5.9 Integrations and outbound traffic
- **ELM completions (writes to ELM).** `local_psaelmsync`'s observer for `\core\event\course_completed` POSTs straight to
  `get_config('local_psaelmsync', 'completion_apiurl')` with `completion_apitoken`, using `curl_init`
  (deployed `classes/observer.php`, lines 118–155). Its "completion" scheduled task has an empty `execute()`. So **any**
  completion on a copy, whether from cron's completion processing or an admin action, would report to the real ELM.
  Disabling scheduled tasks is not enough (R2).
- **ELM enrolment data (reads).** `local_psaelmsync` reads ELM enrolment data from CData at `analytics-api.psa.gov.bc.ca`; the legacy webroot also
  has `cdata-proxy.php`.
- **`local_githubsync` is unused** (owner, 2026-11-18). Prod has one saved configuration with automatic sync off.
- **SMTP:** prod `smtphosts = apps.smtp.gov.bc.ca`.
- **SSO:** test and prod both use Moodle core `oauth2`, with the "BC Government Login" issuer enabled.
- **Web services:** enabled in prod, with 25 token records, not yet classified (step 0.9).
- **Custom webroot files in the legacy image:** `cdata-proxy.php`, `list_courses.php`, `find-courses-with-tag.php`,
  `update-course-tag.php`, `migrate-courses` (a ConfigMap mounted into the webroot), `fix-mojibake*.php` and
  `moodle_index_during_maintenance.php`.

### 5.10 Maintenance modes (deployed `admin/cli/maintenance.php`, verified 2026-11-18)
| Command | Mode | Who gets in | Cron |
|---|---|---|---|
| `php admin/cli/maintenance.php --enable` | **CLI maintenance.** Writes `climaintenance.html` in dataroot and sets `maintenance_enabled = 'cli mode'` | Nobody over the web, including admins and web-service callers | Suspended |
| `php admin/cli/maintenance.php --enableold` | **Web maintenance** (`maintenance_enabled = 1`) | Admins, and web-service callers with maintenance access | **Not** suspended |
| `php admin/cli/maintenance.php --disable` | Off (`maintenance_enabled = 0`, file removed) | Everyone | Normal |

- **Use:** CLI maintenance to freeze a source (legacy at cutover, the new stack at bail-out). Web maintenance on the new site
  between CP1 and reopening, with cron off and the outbound guard on, so admins can check it.
- The legacy wrapper `config/moodle/enable-maintenance-mode.sh` passes `--enable --wait`. `--wait` is not a valid option, so
  **the wrapper is never used**.
- Because `maintenance_enabled = 'cli mode'` is in the database, a copy taken during CLI maintenance should start in web maintenance
  even without `climaintenance.html`. Rehearsal confirms this.
- Maintenance mode alone does not prove that every writer has stopped. §13.1 adds the drain and the quiescence check.

### 5.11 Legacy `config.php` settings that psa-moodle does not set
- `disablelogintoken = true`
- `xsendfile = 'X-Accel-Redirect'`, with aliases
- `debugsessionlock = 10`
- `langstringcache`, `cachejs` and `enablecssoptimiser`
- `session_redis_serializer_use_igbinary = true`
- `wwwroot` derived from the request's `HTTP_HOST`

Each one needs a decision, recorded in §16.

### 5.12 Data quality
- **Prod mojibake fix:** scheduled for 2026-11-18 at 15:30, following its own runbook. Phase 1 uses the **post-fix** prod backup.
- **Test mojibake:** 51 known values plus one U+FFFD, all in courses that will not be used. The owner decided on 2026-11-18 **not
  to fix** them. Test's acceptance census expects exactly these.

## 6. Open questions for the owner

Each one has a default for when it goes unanswered. Phase 0 answers some of them from read-only checks.

| ID | Question | Why it matters | Default if unanswered |
|---|---|---|---|
| Q1 | Who owns `learning.gww.gov.bc.ca` (DNS and certificate renewal)? What are test's public hostnames? | Cutover repoints these Routes, and certificates must survive | Patch the existing Route objects in place; never delete or recreate them |
| Q2 | SSO is core `oauth2` ("BC Government Login") in both. Who can change its redirect URIs? Does anything need `disablelogintoken`? | Login must work the minute the Routes move | Keep the same hostnames, so redirect URIs don't change. Keep `disablelogintoken` until we know. |
| Q3 | `local_psaelmsync` writes completions to ELM (§5.9). Is the ELM endpoint IP-allowlisted? Can ELM tell us if it receives duplicates or test traffic? | Outbound safety, and the first post-reopening check | Treat any POST from a copy as an incident |
| Q4 | *Answered 2026-11-18: GitHub sync is unused.* | | Kept disabled on copies |
| Q5 | Do course developers use the tag-based migration script, or move `.mbz` files by hand? | The script breaks after the replatform | Assume manual; tell the developers |
| Q6 | Do any other systems read the Moodle database directly, or call Moodle web services (reporting, Power BI, other LMSs)? 25 token records exist in prod. | They would break, or be blocked by the guard, at cutover | Phase 0 classifies the tokens and lists database users |
| Q7 | Who must be told about downtime? Is there a change-approval process, and which windows are acceptable? | Comms and approvals | The owner decides each time |
| Q8 | Does anyone use the custom webroot scripts (§5.9)? | Whether the new image must carry them | Don't carry them; Phase 0 checks the access logs |
| Q9 | How long should the bail-out windows be for test and prod, and who makes the go/no-go call? | Legacy must be kept frozen for that long | Test 5 business days; prod 10 business days; the owner decides |
| Q10 | Do the `bht_*` and ad-hoc `local_psaelmsync_logs_*` tables need keeping beyond the archived dumps? | They are not migrated | The archived dumps are enough |
| Q11 | Where does the off-site copy of the new stack's backups go (S12)? | Platform best practice; C8 | A copy to `netapp-file-backup`, which OCIO backs up daily |
| Q12 | Who can approve the GitHub changes (disabling `build.yml`; environment protection)? What is moodle-nginx's default branch? | E4 | The owner does it |
| Q13 | Where should images live: an existing 950003 Artifactory repository, or 950003-tools? | a58ce1 is going away | Whichever already exists for 950003 |
| Q14 | Who receives alerts, and who is on call? | Monitoring; S12 failure alerts | The owner |
| Q15 | Are there events to avoid when choosing windows (cohort starts, deadlines)? | Choosing windows | Ask before each window |
| Q16 | Is copying production personal data to the owner's encrypted laptop acceptable under PSA policy for the migration pipeline? | §13 uses a local pipeline | It was done on 2026-08-26 and 2026-11-17; confirm |
| Q17 | Legacy dev is broken (Galera 4/5, Routes on the maintenance page). Repair it in dev, or rehearse Pass B another way? | Pass B needs a healthy legacy source | After E4 stops the weekly damage, repair legacy dev as its own approved dev-only step |
| Q18 | Test's health monitor runs in automatic mode with the Galera scale-to-zero failsafe. Switch it to `MANUAL_MODE=true` now, ahead of this plan? | It is a live risk to test today, independent of the replatform | Recommended; one approved change to test |

## 7. Phase 0: read-only discovery (this is where we start)

**Purpose:** replace assumptions with facts, answer the §6 questions, and produce the quota numbers.
**Cluster changes:** none. Every command is a `get`, `describe`, `logs` or read-only `exec`. SQL runs inside
`START TRANSACTION READ ONLY`. The 2026-11-18 review already gathered some of this (§16); Phase 0 re-verifies it.

| Step | What | How (all read-only) |
|---|---|---|
| 0.1 | Log in to Silver and set a context for each namespace | `oc login`; then `oc --context "$CTX_DEV" whoami` (and the same for test and prod) |
| 0.2 | Inventory each namespace | `get quota`, `deploy,dc,sts,cronjob,job,hpa,pdb`, `svc`, `route`, `pvc` (with access modes), `networkpolicy`, `cm`, `secret` (names only), `sa,role,rolebinding`, Helm release secrets; `imagestream` in 950003-tools |
| 0.3 | Check for name collisions | `helm template psa-moodle chart/psa-moodle -f values.yaml -f values-950003-<env>.yaml`, list kind/name, and intersect with the live objects. **Expected: no matches.** |
| 0.4 | Review NetworkPolicies | Record the union per namespace (§5.8). Confirm no chart policy selects a legacy pod. |
| 0.5 | Do the quota arithmetic | Per environment and storage class: hard minus used, against the new stack's **admitted** requests (from the PoC's running pods, then from dev Pass A), plus surge and backup Jobs. Decide the temporary request for prod (and test). |
| 0.6 | Check Crunchy on Silver | `oc api-resources --api-group=postgres-operator.crunchydata.com`. RBAC blocks cluster-scoped reads, so ask the platform team for the operator version if needed. |
| 0.7 | Decide where images live | Look for 950003 Artifactory objects in 950003-tools and the pull-secret names in each namespace (Q13) |
| 0.8 | Check legacy automation | Health-monitor settings and **where its alerts go**; how legacy cron runs; legacy HPAs (scaling a target to 0 under an HPA); `gh workflow list` and `gh run list` for moodle-nginx, and the default branch (`gh api repos/bcgov/moodle-nginx --jq .default_branch`) |
| 0.9 | Read Moodle settings (SQL, prod and test) | Enabled auth plugins; OAuth2 issuers (names and enabled flags only); **every `local_psaelmsync` and `local_githubsync` setting name** (names only, to build the guard's override list); enabled scheduled tasks for `local_*` with their last runs; web-service tokens by service, user and last access (no token values); users with `moodle/site:maintenanceaccess`; database users (`mysql.user` names and hosts); `pathto*` settings; `backup_auto_destination`; repository instance types |
| 0.10 | Check custom script usage | Grep legacy web-pod logs for requests to the §5.9 scripts (Q8) |
| 0.11 | Measure data sizes | Database size from `information_schema`; moodledata from `df` plus `SUM(filesize)` over distinct `contenthash`; **free space on each Galera PVC** (`df` in each Galera pod) |
| 0.12 | Check how legacy serves maintenance | Whether `maintenance-message` exists and runs in each namespace; whether legacy web and php serve `climaintenance.html` without Redis (answered in dev Pass B) |
| 0.13 | Record every Route | Host, `spec.to`, port, TLS termination, whether a certificate is present, annotations. Save full YAML to the private folder (it contains certificate keys; S9). |
| 0.14 | Record the results | Fill §16, answer what we can in §6, and update §5 |

**Exit gate:** the owner has read the findings, and reviewers' blocker findings on this draft are resolved.

## 8. Phase 1: local preparation (no cluster changes)

Work on a branch (`replatform-950003`) and have changes reviewed. Nothing here touches OpenShift.
The one exception is pushing images, which happens only once the image home is agreed and is approved as its own step.

### 8.1 Chart changes
- **C1:** render nginx's FastCGI upstream from the release's own php Service, for example with a ConfigMap carrying
  `fastcgi_pass <fullname>-php:9000`, and delete the literal `php` Service.
- **C2:** add `install.enabled` (default `true`). Migrated installs set it to `false`.
- **C3:** add `cron.enabled`, so cron runs 0 or 1 replicas.
- **C4:** scope every NetworkPolicy to release selector labels, with no `podSelector: {}` anywhere.
- **C5:** add `moodle.outbound: off | on` (default `off`), which sets `MOODLE_OUTBOUND` for php and cron (§8.2).
- **C6:** add `values-950003-{dev,test,prod}.yaml` with:
  - temporary hostnames, such as `psa-moodle-950003-dev.apps.silver.devops.gov.bc.ca`;
  - the image home and the per-environment image (C10);
  - sizes that fit the Phase 0 quota numbers, with `maxSurge` set so a rollout fits in quota;
  - `restoreRehearsal` off until storage headroom is confirmed (this covers C7);
  - alert recipients.
- **C8:** add the off-site copy and the scheduled moodledata backup that S12 requires (Q11).
- **C9:** add an SMTP egress policy for php and cron to `apps.smtp.gov.bc.ca`, rendered only when `moodle.outbound=on`.
- **C11:** the Route timeout is applied to the public Routes by the cutover patch (§13.2), and by the chart from Phase 5.
- **C12:** nginx adds a response header `X-PSA-Stack: psa-moodle` (and the release name) to every response.
- **Egress for copies:** add `networkPolicy.externalEgress: on | off`. `off` drops the broad external HTTPS allowance; dev
  rehearsal copies use it. Test and prod need HTTPS egress for SSO at CP3, so there the guard (§8.2) and cron off are the controls.
- **Route:** the chart's Route only ever carries the temporary hostname. **The public Routes stay legacy objects** until
  Phase 5. Cutover patches their backend (§13.2), and Phase 5 adopts them into the chart.
- **Collision check:** add `ops/replatform/check-collisions.sh` (read-only). It renders the chart and compares the names with the live objects.
- **Validation:** `helm lint`, `helm template` and the collision check.

### 8.2 Image changes
- **Exact code (C10, S7).** Build one image per legacy build:
  - **test image:** Moodle core at the exact commit for `2024100711.03` (Build 20260519);
  - **prod image:** Moodle core at the exact commit for `2024100711.04` (Build 20260525);
  - every add-on, including `report_allbackups` and the theme, at the commit whose code matches what legacy runs.
- **Prove it.** Compare checksums of the image's code tree with the legacy pod's `/var/www/html` (read-only listing), excluding
  `config.php` and the documented custom webroot files. Every other difference is explained in writing or fixed. Also compare each
  add-on's `version.php` with `config_plugins` in the source dump: they must be **equal**, not merely newer.
- **The outbound guard (C5, R2).** In `config.openshift.php`, unless `getenv('MOODLE_OUTBOUND') === 'on'`:
  - `$CFG->noemailever = true;`
  - `$CFG->enablewebservices = 0;`
  - `$CFG->forced_plugin_settings['local_psaelmsync']`: every URL setting found in step 0.9 is set to
    `http://127.0.0.1:9/outbound-disabled` (connection refused at once), and every token setting to an empty string;
  - the same for `local_githubsync`;
  - `$CFG->scheduled_tasks`: disable `local_psaelmsync` and `local_githubsync` tasks. Verify the 4.5 wildcard syntax.
  - `ops/replatform/check-outbound-guard.php` prints the effective values through `get_config()`, and runs at every checkpoint.
- **Admins on a guarded copy** must not mark courses complete. If one does, the guard sends the POST to a dead local address.
- Decide each legacy setting in §5.11 and record the decision in §16.
- Confirm how a migrated site gets its Valkey cache-store configuration. `muc/config.php` is **not** copied from legacy.

### 8.3 Migration tooling: small, reviewed, deleted after Phase 5
These go in `ops/replatform/`:
- `migrate-config.php`: the source-side `config.php` for `tool_dbtransfer` (MariaDB, prefix `''`, a scratch dataroot).
- `local-pipeline.sh`: restore the dump into MariaDB 10.6.20; run `admin/cli/check_database_schema.php`; drop the
  **reviewed** list of non-schema tables **in the local copy only**; **stop if any version differs** from the image (S7);
  run `migrate.php --dbtype=pgsql --prefix=mdl_ …` into local Postgres 15; then `pg_dump -Fc`.
- `compare-content.sh` (R12): for every table, export rows ordered by primary key with normalized types, and compute a SHA-256
  per row and per table on both sides, with the prefix mapped. Report any table whose hash differs.
  `expected-differences.md` lists each accepted difference with its reason, starting with `log_display` (rebuilt by
  `tool_dbtransfer`). Any difference not on the list is a no-go.
- `moodledata-copy-job.yaml`: a one-off Job that mounts the legacy moodledata PVC **read-only** and the new PVC read-write, and runs
  `rsync -a` excluding `cache/ localcache/ sessions/ temp/ lock/ trashdir/ muc/ climaintenance.html`.
- `check-filedir`: confirms that every non-directory `contenthash` in `files` exists in the target filedir, with the right size,
  and that each file's SHA-1 equals its name.
- `bailout-import.sh` (§14): loads a MariaDB dump into a **new** database `moodle_bailout`, and never into `moodle`.
- `bailout-swap.sql`: one `RENAME TABLE` statement that moves every `moodle.*` table to `moodle_frozen.*` and every
  `moodle_bailout.*` table to `moodle.*`, generated from the table list and reviewed. `bailout-unswap.sql` is its exact reverse.

### 8.4 Full local rehearsal
Use the **post-fix prod dump** and the test dump. The local stack runs on a Podman network created with `--internal`, so it
has no route to the internet.
1. Restore, then run the schema check. Expect **only** the extra tables in §5.2, then drop them in the copy.
2. Run `tool_dbtransfer` into Postgres and time it. Run `compare-content.sh`: only the expected differences.
3. Boot psa-moodle locally against the Postgres copy with a sample of moodledata. Check that `admin/index.php` shows
   **no pending upgrade**, the environment check passes, the site starts in maintenance (§5.10), and pages work.
4. **Guard test (R2):** with the guard on, complete a course as a test user. Confirm the ELM POST went to the dead address
   and nothing else, and that no email left.
5. **Reverse direction with new writes (R12):** create a user, a course and an enrolment, and complete an activity. Run
   `tool_dbtransfer` from Postgres into an empty local MariaDB; run `compare-content.sh` again; boot the **legacy** code against
   it and confirm the new records are there, with no pending upgrade. Then create another record, to prove IDs continue correctly.
6. Rehearse `bailout-swap.sql` and `bailout-unswap.sql` on a local MariaDB.
7. Write the measured timings into §13.

**Exit gate:** reviewers sign off v1.0 of this runbook, and the owner approves the start of Phase 2.

## 9. Phase 2: 950003-dev (the only place for experiments)

- **2.0 Prerequisites.**
  - **E4, GitHub (once, for all environments):** disable the `build.yml` workflow (`gh workflow disable`) and cancel any queued
    or running runs. Recommended at the same time: required reviewers on the GitHub environments, and branch protection on
    `950003-test` and `950003-prod`.
    *Restoration condition:* re-enable only if the replatform is abandoned for an environment, and only after its pipeline is fixed.
  - **E4, dev:** scale the dev pod-health-monitor to 0. *Restoration condition:* scale to 1 if the replatform of that
    namespace is abandoned. Test and prod do the same before their own coexistence starts (§10, §11).
  - Save the legacy dev objects as YAML into the private folder (read-only).
  - Repair legacy dev if Q17 says so: Galera 5/5 and Routes back on `web`. This happens only in dev.
- **Pass A: coexistence with an empty install.**
  - `helm install psa-moodle` with `install.enabled=true`, the temporary host, `outbound=off` and `externalEgress=off`.
  - Verify the legacy object list and the legacy site are **unchanged**; compare before and after.
  - Record the **admitted** requests of every new pod, including sidecars, for §5.4 and step 0.5.
  - Then exercise the new stack: a pgBackRest backup, a restore drill (dev only), pod-kill and PDB behaviour, and alerts.
  - **Undo:** `helm uninstall psa-moodle`. Then delete the listed `psa-moodle-*` PVCs, the PostgresCluster, and any Secrets
    the chart keeps (the admin Secret has `helm.sh/resource-policy: keep`).
- **Pass B: dress rehearsal of the cutover (§13) and the bail-out (§14).** Legacy dev is the source, and the legacy dev Routes play
  the public Routes. Run with the prod scaling order (§11.2). Each run must include:
  - a rollback at **every** checkpoint at least once, using the full reverse sequence (§13.4);
  - one complete forward run to reopening;
  - a **deliberately failed reverse import** (stopped halfway), recovered by dropping `moodle_bailout`, with the frozen
    `moodle` database proven untouched;
  - one complete bail-out to legacy dev, including the swap, unswap and swap again;
  - a check that legacy serves the CLI maintenance page with Redis scaled to 0 (step 0.12).

  Time everything. **Do this twice cleanly.**
- **Pass C: production-scale acceptance**, storage permitting.
  - Load the post-fix prod database (through the local pipeline) and prod moodledata (streamed read-only through the laptop,
    or a subset) into the new dev stack, with `outbound=off` and `externalEgress=off`.
  - Run §15 and compare page timings with legacy prod.
  - Demonstrate the combined database-and-files restore that S12 requires.
- **Soak for one week:** backups, alerts, and cron with the guard on and no internet.

**Exit gate:** two clean Pass B runs as above; a measured window length the owner accepts; the S12 restore demonstrated;
and sign-off from reviewers and the owner.

## 10. Phase 3: 950003-test (production-grade)

- **Before:** tell the course developers; agree the window; take fresh verified backups of the database **and** moodledata;
  confirm the quota.
- **E4 in test:** scale test's pod-health-monitor to 0 before the new stack is installed (if Q18 hasn't already made it manual).
- **Some days before:** deploy the new stack beside legacy with the **test image (`.03`)**, `install=false`, `outbound=off`
  and `cron=off`, then pre-copy moodledata with the copy Job. That is safe while legacy is live, because filedir is
  content-addressed and append-only.
- **The window:** follow §13. SSO only works on the public hostname, so it is checked at CP3.
- **Bail-out window (Q9):**
  - legacy test stays frozen, with Galera running and its cron at 0;
  - course developers work on the new stack.
- **Prove the course flow:** a course backed up from the new test must restore into legacy prod. Course developers do this
  as normal business.
- **Build alignment:** test moves to prod's build (`.04`) as a normal upgrade in its own window, only after **both** test's
  and prod's bail-out windows have closed.

**Exit gate:** sign-off from the owner and the course developers, and the bail-out window closed.

## 11. Phase 4: 950003-prod

### 11.1 Before the window
- **Submit the temporary quota request early,** using the Phase 0 numbers and the wording of platform docs Example 3.
- **Tell learners** and agree the window.
- **E4 in prod:** scale prod's pod-health-monitor to 0 before the new stack is installed.
- Deploy the new stack in its smallest shape with the **prod image (`.04`)**, `install=false`, `outbound=off`, `cron=off`;
  pre-copy moodledata.
- Recompute the quota with admitted requests at T−1d.

### 11.2 Scaling sequence in the window (rehearsed in dev Pass B)
Forward, after the freeze and final dump (§13.1):
1. Scale legacy `redis-proxy`, `sentinel` and `redis` to 0 (E2). Legacy web and php keep serving the CLI maintenance page,
   which needs neither Redis nor the database (proven in Pass B). This frees about 1.75 CPU.
2. Legacy cron is already at 0 from the freeze. Galera is never touched.
3. Scale the new stack to the prod shape and wait until every pod is ready.

Reverse (any rollback before the commit point): see §13.4.

### 11.3 Window and bail-out
- **Window:** follow §13.
- **Bail-out window (Q9):** legacy Galera keeps running, frozen and untouched.
- **Backups (S12)** are working before reopening, not after.

## 12. Phase 5: decommission (per environment, dev first, after its bail-out window and sign-off)

1. Confirm that the pre-cutover dumps and moodledata copies are archived and readable.
2. Scale the remaining legacy workloads to 0, Galera last, and wait an agreed number of days.
3. Delete the legacy objects **by name from a reviewed list**, never by label or `--all`. PVCs go last.
4. Adopt the public Routes into the chart, and remove the chart's temporary Route.
5. Review the namespace-wide NetworkPolicies (§5.8).
6. Return the temporary quota. Archive the moodle-nginx workflows and mark the repository read-only.
7. Retire a58ce1 (including the learningcurator leftovers) and release ad4087.
8. Update `README.md`, `CLAUDE.md` and this runbook.

## 13. The cutover window (used in dev Pass B, test and prod)

The timings are placeholders until Phase 1 measures them. Every step is approved in advance as a set, and each
checkpoint (CP) is an explicit go/no-go call by the owner. Throughout, until §13.3: **new cron is 0, the outbound guard is on.**

### 13.1 Freeze legacy (R3)
| T | Step | Verify | Undo |
|---|---|---|---|
| T−7d | New stack deployed (`install=false`, `outbound=off`, `cron=off`, temporary host); moodledata pre-copied | Collision check clean; legacy unchanged | `helm uninstall` and delete its PVCs |
| T−1d | Backups verified; comms sent; quota recomputed; laptop on power and wired, sleep disabled | n/a | n/a |
| T0 | **E1:** `php admin/cli/maintenance.php --enable` in one legacy php pod | Public URLs return the maintenance page to anonymous users **and** an admin session; a web-service call is refused | `--disable` |
| T0 | **Drain:** wait for running scheduled and ad hoc tasks to finish (CLI maintenance stops new cron runs) | No cron or ad hoc PHP processes in the cron pod; no `task_adhoc` rows with a `timestarted`; limit 15 minutes, then the stop rule | n/a |
| T+? | **E2:** scale legacy cron to 0 | Pod gone | Scale to 1 |
| T+? | **Quiescence:** Galera `wsrep_last_committed` unchanged for 5 minutes; no client connections except ours | Both hold | Find the writer before continuing |
| T+? | Final `mariadb-dump --single-transaction`, verified for footer, table count and checksum | As in BACKUP-NOTES | n/a (read-only) |
| T+? | Final moodledata delta copy (Job) | `rsync` exit 0 | Delete the Job |
| T+? | Local pipeline: restore, schema check, drop extra tables in the copy, version check, `tool_dbtransfer`, `compare-content.sh` | Only expected differences | n/a (local) |
| **CP1** | **Go/no-go: is the data correct?** | | No-go: §13.4. **No data lost.** |

### 13.2 Load, check, switch (R7, R8)
| T | Step | Verify | Undo |
|---|---|---|---|
| T+? | §11.2 forward scaling (prod) | Pods ready; quota not exceeded | §13.4 |
| T+? | `pg_restore` into the new primary; `compare-content.sh` against the frozen source; `check-filedir` | Only expected differences; no missing or mismatched files | Drop and recreate the new database; then §13.4 |
| T+? | Site in **web** maintenance (from the copied flag, or `--enableold`); purge caches; `check-outbound-guard.php` | No pending upgrade; guard values correct | n/a |
| T+? | Admin checks through the **temporary** Route, with wwwroot still on the temporary host and the local admin account | Every response carries `X-PSA-Stack: psa-moodle` | n/a |
| **CP2** | **Go/no-go: does the new site work for admins?** | | §13.4 |
| T+? | Save both Routes' YAML (S9) and generate exact undo patches. `helm upgrade` wwwroot = public hostname (still maintenance, cron 0, guard on) | Pods ready | `helm rollback` |
| T+? | **E3:** patch **both** prod Routes (`moodle-custom` and `moodle-web`): `spec.to.name` → `psa-moodle-web`, `spec.port.targetPort` → `http`, timeout annotation `900s`. Certificates untouched. | Both hostnames return `X-PSA-Stack: psa-moodle`; the custom certificate is still served | Apply the saved undo patches (Routes first), then `helm rollback` |
| T+? | Admin checks through both public hostnames, including **SSO login**; spot checks from §15 | | |
| **CP3** | **Go/no-go: open the site?** | | Routes back, then §13.4. **No data lost.** |

### 13.3 The commit point (S11, S12)
| T | Step | Verify |
|---|---|---|
| T+? | **Backups before opening (S12):** pgBackRest full backup after the restore has succeeded; the scheduled database and moodledata backups and the off-site copy are in place, with failure alerts | Each one has a successful run |
| T+? | `helm upgrade` with `outbound=on` and `cron=on` (this also renders the SMTP egress policy, C9) | `check-outbound-guard.php` shows real values; a cron run succeeds |
| T+? | `php admin/cli/maintenance.php --disable` on the new site; announce | Learners and authors can log in; a test email arrives; the first ELM completion after opening is seen in the plugin's log |

From here on, going back means §14.

### 13.4 Reverse sequence (any rollback before the commit point, R6)
1. **Stop the new stack's processing first:** confirm new cron is 0 and the guard is on; put the new site in CLI maintenance.
2. If the Routes were switched: apply the saved undo patches to both Routes. Verify both hostnames no longer return `X-PSA-Stack`.
3. Scale the new stack to its smallest shape (or 0) to release CPU. Wait until its pods are gone.
4. Scale legacy `redis` and `sentinel` up; wait for Sentinel to report a master and quorum. Then `redis-proxy`; wait until ready.
5. If legacy web or php were scaled down, scale them back to their recorded replica counts (respecting any HPA); wait until ready.
6. **E1:** `php admin/cli/maintenance.php --disable` on legacy. Check the site as an anonymous user and as an admin.
7. **E2:** scale legacy cron to 1 and confirm a cron run succeeds.
8. Leave the health monitor at 0 until the owner decides whether the replatform continues (E4 restoration condition).

## 14. Bail-out procedure (reverse migration after the commit point, R4)

The frozen legacy database `moodle` is **never written** by this procedure until step 8, and step 8 is reversible.

1. **Stop the new stack's processing:** agree a window; `maintenance.php --enable` (CLI) on the new site; drain tasks as in §13.1;
   scale new cron to 0; `helm upgrade` with `outbound=off`. Quiescence: Postgres `xact_commit` unchanged for 5 minutes; no other
   client sessions.
2. `pg_dump` the new database and copy it locally. Restore it into local Postgres.
3. Run `tool_dbtransfer` into an empty local MariaDB 10.6.20 with prefix `''` (exact code, S7). Run `compare-content.sh` between
   Postgres and MariaDB. Then `mariadb-dump` the result.
4. **Pre-checks:** Galera 5/5 and Synced; free space on **every** Galera PVC is at least twice the database size (step 0.11).
5. **E5:** `bailout-import.sh` creates `moodle_bailout` and loads the dump into it. Then `compare-content.sh` against the local MariaDB.
   **If the import fails at any point:** `DROP DATABASE moodle_bailout`. The frozen `moodle` database is untouched; retry, or
   decide on the last resort.
6. **E5, files:** rsync the new filedir into legacy moodledata with `--ignore-existing` (add-only; names are content hashes).
   Then `check-filedir` against the `files` table in `moodle_bailout`.
7. Go/no-go on the verified `moodle_bailout`.
8. **E5, swap:** run `bailout-swap.sql` (one atomic `RENAME TABLE`). The frozen tables are now in `moodle_frozen`.
   Undo: `bailout-unswap.sql`.
9. **E5:** purge legacy caches (`admin/cli/purge_caches.php`), so Redis holds nothing from before the freeze.
10. Routes back to legacy with the saved patches (E3). Reverse scaling as in §13.4 steps 3–7, which ends with legacy maintenance off.
11. Admin checks on legacy: no pending upgrade; records created on the new stack are present; a new record gets a fresh ID.

**Last resort, if the reverse migration cannot be completed:** if step 8 has run, run `bailout-unswap.sql`. Then Routes back to the
frozen legacy database, accepting the loss of all changes since reopening. The new stack's database and backups are kept, so the
lost work can still be recovered by hand. This is the owner's decision only.

## 15. Acceptance checks (each environment)

- **Data, at CP1 and CP2 (frozen baselines, before any activity):**
  - `compare-content.sh` shows only the differences in `expected-differences.md`;
  - `check_database_schema` is clean;
  - `check-filedir` finds no missing files and no SHA-1 mismatches;
  - mojibake census: prod is zero outside the excluded log tables, and test has exactly the 51 known values plus one U+FFFD.
- **Which stack answered:** every check confirms the `X-PSA-Stack` header.
- **Login:** SSO ("BC Government Login") on the public hostnames and the local admin account.
- **Courses:**
  - course pages, images and files;
  - H5P, both `mod_hvp` and core;
  - lessons, books and quizzes, including an attempt;
  - grades;
  - completion (with the guard on, before opening);
  - search;
  - reports, including `report_allbackups`.
- **Course flow:** back up a course (`.mbz`) and restore it across environments.
- **Before opening (S12):** pgBackRest full backup; scheduled database and moodledata backups; the off-site copy; failure alerts;
  the combined restore demonstrated in dev.
- **After opening:**
  - a test email is delivered (SMTP egress, C9);
  - the first ELM completion POST succeeds, and ELM confirms receipt (Q3);
  - `task_log` shows tasks succeeding, and ad hoc tasks drain;
  - no new errors in the PHP and cron logs.
  - There is **no** row-count comparison after opening: counts change as soon as people use the site.
- **Platform:** the integrity CronJob passes; alerts reach the recipients; the PDBs and HPA behave as expected.
- **Performance:** login and course-page response times no worse than legacy (prod login was about 130 ms on 2026-11-16).

## 16. Decision log and Phase 0 findings

| Date | Decision | By |
|---|---|---|
| 2026-11-17 | 950003-test is production-grade; dev is the only experiment target | Owner |
| 2026-11-17 | Replatform in place inside 950003 instead of ad4087 or a new project set | Owner (leaning; this runbook is the plan under review) |
| 2026-11-18 | Don't fix test's 51 mojibake values (they're in courses that won't be used) | Owner |
| 2026-11-18 | Fix prod mojibake before migration; window at 15:30 on 2026-11-18 | Owner |
| 2026-11-18 | GitHub sync is unused; keep it disabled on copies and drop it from acceptance | Owner |
| 2026-11-18 | Accept review findings R1–R12 into v0.2 | Owner |
| 2026-11-18 | Freeze with CLI maintenance; never use the legacy maintenance wrapper | v0.2 (for review) |
| 2026-11-18 | Pin each environment's image to its legacy build; align test to prod only after both bail-out windows | v0.2 (for review) |
| 2026-11-18 | Bail-out imports into `moodle_bailout`, then swaps with one `RENAME TABLE` | v0.2 (for review) |

**Pre-Phase-0 findings (independent review, 2026-11-18; Phase 0 re-verifies):**
- Quota and Routes as in §5.4 and §5.7; NetworkPolicies as in §5.8; health monitors as in §5.5.
- Both environments use core `oauth2` with "BC Government Login".
- Prod: `smtphosts = apps.smtp.gov.bc.ca`; web services enabled with 25 token records; all tables InnoDB.
- Legacy dev: Galera 4/5; Routes on `maintenance-message`.
- Test: `maintenance_enabled = 1` at the time of the review (web maintenance, set for the 2026-11-17 backup). The owner confirms
  whether that is intended.
- The PoC's Crunchy pods carry sidecars (§5.4).

Phase 0 findings: *(empty)*

## 17. References
- **Review of v0.1:** [replatform-950003-review.md](replatform-950003-review.md)
- **Moodle:** [Administration via command line, Maintenance mode (4.5)](https://docs.moodle.org/405/en/Administration_via_command_line#Maintenance_mode)
- **Platform docs** (`../platform-developer-docs/src/docs/`):
  - `automation-and-resiliency/request-quota-adjustment-for-openshift-project-set.md` (Example 3, temporary quota for a migration)
  - `platform-architecture-reference/openshift-network-policies.md` (default deny in every namespace; policies are additive)
  - `database-and-api-management/postgres-how-to.md` (Crunchy; `netapp-block-standard` for database PVCs)
  - `database-and-api-management/database-backup-best-practices.md`
  - `platform-architecture-reference/platform-storage.md` (`netapp-file-backup` is backed up daily by OCIO)
- **This repository:**
  - `CLAUDE.md`
  - `README.md` ("Environment roles: read this first")
  - `chart/psa-moodle/templates/networkpolicy.yaml`, `route.yaml`, `php-service.yaml`, `job-install.yaml`, `monitoring.yaml`
  - `Containerfile.php`, `config/moodle/config.openshift.php`
  - `docs/phase3-deploy.md` to `docs/phase6-backups.md`
  - `docs/legacy-comparison.md`
  - `docs/discovery-inventory.md`
- **Legacy:**
  - `../moodle-nginx/README.md`
  - `.github/workflows/build.yml` and `cleanup.yml`
  - `openshift/scripts/utils/maintenance-mode.sh`, `openshift/scripts/remove-maintenance-message.sh`
  - `config/moodle/enable-maintenance-mode.sh`, `config/moodle/remote.config.php`
- **Private, not in git:** the prod mojibake runbook and the verified backups under `~/Moodle/private-backups/`.
