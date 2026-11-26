# Pass B, window 1: the cutover rehearsed on legacy dev, rolled back at CP3

The runbook's §13 run against **950003-dev only**. It goes forward through CP1, CP2 and CP3, then takes the CP3 rollback
(§13.4) back to exactly the recorded state. There is **no commit point** in this run; a later Pass B run goes through
it, and through a return (§14). Test and prod are not touched.

- **Approval:** the owner approves this set of steps once (S5, §13: "approved in advance as a set"). Then each
  checkpoint (CP1–CP3) is the owner's own go/no-go call, and each `deploy-950003` run waits at its GitHub gate.
  Anything not written here needs its own approval.
- **Stop rule (S10):** anything unexpected means stop, return to the last known-good state, and write down what
  happened.
- **Latest-abort time:** if CP3 isn't reached by **T0 + 3 h**, roll back from wherever the window is (§13.4).
  Estimate from the 2026-11-26 dry run: about 2.5 h, including the rollback.
- **Run folder (S9, owner-only):** `~/Moodle/private-backups/passb-950003-dev-<window>/` (dumps, lists, Route undo
  patches, window log). Shell variables below: `NS=950003-dev`, `R=psa-moodle`, `RUN=<run folder>`, and
  `PG=$(oc -n $NS get pod -l postgres-operator.crunchydata.com/cluster=psa-moodle-pg,postgres-operator.crunchydata.com/role=master -o name)`.

## Already done (2026-11-26)
- **Bootstrap:** the fenced release is installed (`dev-pass-b`, the dev build from `build-exact` run 45884132438), the
  Postgres primary is ready, and the database is empty.
- **The Route refusal is proved (S15).**
- **Files pre-copied:** 6,120 copied and verified, with legacy dev's own 1,399 missing files as the known list.
- **Local dry run on a pre-window dump:** the conversion (289 s, 511 tables and 1,054,418 rows identical) and the
  forward comparison (expected differences only). It found and fixed `version-compare.php`'s text comparison.

## Before the window (each its own approved dev change)
| # | Step | Command | Verify | Undo |
|---|---|---|---|---|
| P1 | **E4, dev:** pause legacy dev's health monitor | `oc -n $NS scale deploy/pod-health-monitor --replicas=0` | Pod gone | Scale to 1 (the restoration condition: the replatform of dev is abandoned) |
| P2 | **Q17:** repair legacy dev so the rehearsal starts from a working site. Its `moodle-web` Route goes back on `web` (port 8080 on both); `redis-insight` stays on the maintenance page | `oc -n $NS patch route moodle-web --type=merge -p '{"spec":{"to":{"name":"web"}}}'` | The legacy login page through `https://moodle-950003-dev.apps.silver.devops.gov.bc.ca/` (HTTP 200, no `X-PSA-Stack`); Galera 5/5 Synced | Patch back to `maintenance-message` |
| P3 | Capture the repaired state as the window's baseline | `state-capture.sh $NS passb1-ready` | Saved privately | n/a |
| P4 | The reviewer account on the **copy only**: legacy dev's generic `admin` (id 2, created by the installer, manual login; `REVIEWER_ADMINS=2`). Its email is a former colleague's, so on the copy the owner sets **their own password and email**; nobody else's credentials are needed or used, and the guard sends no mail either way. Legacy dev's own `admin` is never touched. (Test and prod use the owner's own SSO account instead.) | At T+45 below, never on legacy | n/a | The copy is discarded |

## The window
| T | Step | Command (abridged; scripts print their own checks) | Verify | Undo |
|---|---|---|---|---|
| T0 | Capture (S14) | `state-capture.sh $NS passb1-precutover` | Saved privately | n/a |
| T0 | **E1:** CLI maintenance on legacy dev | `oc -n $NS exec deploy/php -- php /var/www/html/admin/cli/maintenance.php --enable` | The public URL and legacy `web` itself serve Moodle's maintenance page (503) | `state-restore.sh passb1-precutover` |
| T0 | **Drain** | `oc -n $NS exec deploy/cron -- pgrep -af cron.php` is empty; `SELECT COUNT(*) FROM task_adhoc WHERE timestarted IS NOT NULL` is 0 (through `rp-mariadb-target.sh`) | Both hold; limit 15 minutes, then the stop rule | n/a |
| T+5 | **E2:** legacy cron to 0 | `oc -n $NS scale deploy/cron --replicas=0` | Pod gone | Scale to the captured 1 |
| T+5 | **Quiescence** | `wsrep_last_committed` unchanged for 5 minutes; `app_connections moodle` is 0 on every Galera node | Both hold | Find the writer first |
| T+12 | **Final dump** (read-only) | As the pre-window dump: `mariadb-dump --single-transaction` from `mariadb-galera-0` into `$RUN` | Footer, 713 tables, SHA-256; after the local load, per-table counts equal the live database's | n/a |
| T+15 | **File delta** | `referenced-files.sql` against the final dump's local copy; the read-only check Job for legacy's own missing files; then `rp-moodledata-copy` again, which resumes | "complete and verified", 0 unexpected missing | Delete the Job and the ConfigMap |
| T+20 | **Local pipeline** | `local-pipeline.sh dev start-mariadb`, `load` (the final dump), `all`; `compare-local.sh dev forward` | Only the expected differences (D6's 3 tables, `log_display`) | n/a (local) |
| **CP1** | **Go/no-go: is the data correct?** | | | No-go: §13.4 |
| T+30 | **Load:** the Postgres dump into the new primary | `oc -n $NS exec -i $PG -c database -- pg_restore --no-owner --role=moodle --exit-on-error --single-transaction -d moodle < $RUN/dev-postgres-*.dump`; then `backup-role-grants.sql` through `psql -X -v ON_ERROR_STOP=1 -v backup_role=moodle-backup` | Per-table row counts equal the local Postgres's (511 tables); the referenced list from the new database equals the final dump's | Drop and recreate the database `moodle`; then §13.4 |
| T+35 | **`deploy-950003` `precommit`**, `site_host=temporary`, overlay `dev-pass-b`, the same digests | Workflow (gate) | Version check passes; the guard is on; `configure-cache.php --check` passes | §13.4 |
| T+45 | On the new site, as §13.2: web maintenance; **clear sessions**; purge caches; the search index if global search is on; `encryption-canary.php create` (run with `MOODLE_ROOT=/var/www/html`); P4's password for id 2 | `oc -n $NS exec deploy/$R-php -- php admin/cli/maintenance.php --enableold`; `psql -c 'DELETE FROM mdl_sessions'`; `php admin/cli/purge_caches.php`; `php admin/cli/reset_password.php --username=admin` (the owner types the password) and the owner's email set on id 2 (copy only) | No sessions; the canary decrypts | n/a |
| T+50 | Reviewer checks through the temporary Route (restricted since creation) | The owner, as id 2 | `X-PSA-Stack: psa-moodle` on every response; the phone on cellular is refused | n/a |
| **CP2** | **Go/no-go: does the new site work for admins?** | | | §13.4 |
| T+60 | Route undo patches from `passb1-precutover`'s YAML, into `$RUN`. **`deploy-950003` `review`**, `site_host=public` | Workflow (gate) | Its review checks pass: HTTPS policy present, no app SMTP policy, cron 0 | `helm rollback` |
| T+70 | `restrict-routes.sh` on `moodle-web` to the reviewer addresses, then **E3:** `moodle-web` to `psa-moodle-web`, target port `http`, timeout `900s` | `restrict-routes.sh $NS $RUN "70.66.217.108/32 142.32.0.0/16" moodle-web --apply`; `oc patch route moodle-web …` | Allowed address: `X-PSA-Stack: psa-moodle`; the phone on cellular: refused | Undo patch (Route first), `unrestrict-routes.sh`, then `helm rollback` |
| T+80 | **SSO login** through `moodle-950003-dev…` by the owner; spot checks with synthetic records only; `reviewer-write-check.sql` | | SSO completes (a new, non-admin account); the guard still passes; the write check finds only the reviewers | |
| **CP3** | **Go/no-go: open the site?** This run's answer is **no-go, by plan**: rehearse the rollback | | | Below |

## The CP3 rollback (§13.4)
| Step | Command | Verify |
|---|---|---|
| 1. **Writer fence**, Route first | `writer-fence.sh $NS $R chart/psa-moodle maintenance-message moodle-web` (it points `moodle-web` at the fence, then the fenced profile, then `verify-fenced.sh`) | `FENCED`; no hostname returns `X-PSA-Stack` |
| 2. Legacy dependencies | Sentinel reports a master and quorum; `redis-proxy`, legacy `php` and `web` are ready | All hold |
| 3. **Separate approval at the time:** restore legacy dev exactly | `RESTORE_SCOPE=all state-restore.sh $NS passb1-precutover psa-moodle --apply` (dry-run first; the release name keeps it off the new stack's Deployments) (maintenance off, cron 1, `moodle-web` back on `web` and unrestricted) | `state-restore.sh … passb1-precutover` reports a match; the legacy login page serves (200, no `X-PSA-Stack`) |
| 4. Record | Timings per step in the window log; the next run's latest-abort time from them | |

The new stack stays installed and fenced with the loaded copy. Before the next Pass B run, the copy is discarded:
drop and recreate the database, or uninstall the release with its volumes. Each is its own approval.

## Result (2026-11-26)
Run: forward to CP3 and the CP3 rollback, 72 minutes; legacy dev restored exactly. Results, defects and lessons are in
the runbook (§9, Pass B, "Window 1 ran"). Lessons for run 2: don't change the reviewer account's email (the issuer
auto-links SSO identities by email); start the write check after the last planned CLI step; run every step under bash
and log only on a zero exit status.
