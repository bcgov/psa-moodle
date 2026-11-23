# Phase 0 findings: replatform 950003 (read-only discovery, 2026-11-18)

Companion to [replatform-950003-runbook.md](replatform-950003-runbook.md) (DRAFT v0.3, §7). Everything here was gathered
read-only on 2026-11-18 between 17:00 and 18:00 MST: `oc get`/`describe`/`logs`, read-only `exec` (`df`, `du`, `find`),
and SQL inside `START TRANSACTION READ ONLY`. Nothing on any cluster was changed.

Raw outputs (Route YAML with certificate keys, Secret names, settings, file lists) are in the owner-only folder
`~/Moodle/private-backups/phase0-20261118/`. Security-sensitive observations are recorded there too and are not in this file.
These findings feed runbook §5, §6 and §16 once the current review is back.

## Summary: what changes the plan

| # | Finding | Effect on the plan |
|---|---|---|
| F1 | **Only one name collision** in all three namespaces: the chart's literal `Service php` (C1). The other 41 rendered objects are clear. | Confirms C1 is the only rename needed |
| F2 | **Prod moodledata: 2.93 GiB is referenced, 8.4 GiB is on disk.** 557 files (5.25 GiB) in `filedir` have no `files` row; 3 referenced files are missing. Test: 110 unreferenced (1.56 GiB), 9 missing. | Copy **referenced files only**: the new prod volume needs about 3 GiB plus growth, not 8.4. Legacy keeps every file until decommission. Missing files go on the expected-differences list |
| F3 | The binding storage limit is the **aggregate** `storage-quota` (96 GiB per namespace), not the per-class quotas | Quota sums use the aggregate; block storage is not separately constrained |
| F4 | A separate **`compute-time-bound-quota`** (4 CPU / 32 GiB, unused) exists in every namespace | Pods with a deadline (backup Jobs) count there, not against long-running CPU |
| F5 | **No HPAs** in any legacy namespace | Reverse scaling (§13.4) only restores recorded replica counts |
| F6 | **All 25 prod web-service tokens are Moodle mobile app tokens** (25 users, last use 2026-11-04, 23 expired). No other database accounts | Q6 answered: no integration depends on web services or direct DB access |
| F7 | **The custom webroot scripts had no requests** in two weeks of prod logs | Q8 answered: the new image does not carry them |
| F8 | The legacy health monitor's **only alert channel is Rocket.Chat**, which is discontinued | Today nobody gets its alerts; Q14 needs a real channel for the new stack |
| F9 | **GitHub sync's scheduled task is enabled and runs** in prod and test (ran 2026-11-18 17:00 MST), though the plugin is unused and its webhook secret is empty | The outbound guard disables it on copies; recommend disabling it in legacy too |
| F10 | Moodle needs `unoconv` and Ghostscript (`pathtounoconv`, `pathtogs` are set) | The new image must include both, or document-to-PDF conversion breaks |
| F11 | 19 site admins in prod, 14 in test | All of them get through web maintenance at CP2/CP3 |

## Step results

### 0.1 Login and contexts
`oc whoami` works in every context. Projects visible: `950003-{dev,test,prod,tools}`, `a58ce1-{dev,test,prod,tools}`, `332842-*`.

### 0.2 Inventory
| Namespace | Workloads | Services | Routes | PVCs | NetworkPolicies | Pods | Helm releases (latest revision, status) |
|---|---|---|---|---|---|---|---|
| dev | 14 | 21 | 2 | 14 | 8 | 18 | `mariadb-galera` r171, `redis` r121, `moodle-db` r276, `950003-dev-mysql` r1 (deployed); `moodle-bitnami` r1 (**failed**) |
| test | 13 | 21 | 1 | 13 | 8 | 24 | `mariadb-galera` r36, `redis` r9, `moodle-db` r39, `moodle-mysql`, `pma`, `phpmyadmin` (all deployed) |
| prod | 23 | 21 | 2 | 11 | 7 | 24 | `mariadb-galera` r1, `redis` r17, `moodle-mysql`, `phpmyadmin` (deployed); `moodle-db` r44 (**failed**) |
| tools | 2 | 4 | 3 | 3 | 4 | 1 | three `*-backups-pma` (deployed) |

Newest Helm activity: dev 2026-11-07 (the last failing weekly deploy), test 2026-09-01, prod 2026-05-26.

### 0.3 Name collisions
`helm template` with `values.yaml` + `values-dev.yaml` and + `values-test.yaml` (39 and 42 objects), compared with live
kind/name in each namespace: **only `Service php`** collides, in dev, test and prod (C1).

### 0.4 NetworkPolicies
- Every namespace: `deny-by-default`, `allow-from-openshift-ingress` (all pods), `platform-services-controlled-default`
  (web terminal, console), and `allow-all-internal` (all pods; from the same namespace and tools; **test also from dev**).
- Legacy-specific policies select only legacy pods by label (`mariadb-galera`, `redis`, `moodle-db` backup, `mysql` backup).
- No legacy policy restricts egress for Moodle pods.
- The chart's `psa-moodle-allow-monitoring` has `podSelector: {}` (C4 confirmed).

### 0.5 Quota (requests; long-running compute)
| Namespace | CPU free | Memory free | Storage free (aggregate) | PVC count free |
|---|---|---|---|---|
| dev | 2.670 of 4 | 28.40 of 32 GiB | **28.66** of 96 GiB | 46 |
| test | 2.625 of 4 | 26.53 of 32 GiB | **18.90** of 96 GiB | 47 |
| prod | 1.025 of 4 | 26.53 of 32 GiB | **2.90** of 96 GiB | 49 |
| tools | 2.000 of 2 | 8.00 of 8 GiB | 18.00 of 64 GiB | 57 |

Legacy uses only `netapp-file-standard` and `netapp-file-backup`. The PoC (a58ce1-dev) admits **0.900 CPU / 2.69 GiB** with
one replica each: Postgres instance 0.400 / 1.25 GiB (4 containers), pgBackRest repo host 0.100 / 512 MiB (2 containers),
php 0.200 / 512 MiB, cron 0.100 / 256 MiB, valkey 0.050 / 128 MiB, web 0.050 / 64 MiB.

Indicative storage for the new stack (to be replaced by dev Pass A numbers): moodledata 3 GiB prod / 2 GiB test
(referenced files, F2) plus headroom; Postgres data about 2–5 GiB; pgBackRest repo about 2× data; Valkey 1 GiB.
Prod therefore needs a temporary storage increase on the order of **15–25 GiB**, not the ~30 GiB a full filedir copy would add.
Test and dev fit within current quota.

### 0.6 Crunchy
PGO `v1beta1` CRDs are present on Silver (`PostgresCluster`, `PGUpgrade`, `PGAdmin`). The PoC's `psa-moodle-pg` runs Postgres 15.

### 0.7 Image home (Q13)
950003-tools has an `ArtifactoryProject` named `moodle` and an `ArtifactoryServiceAccount`. All three namespaces have the pull
secret `artifactory-m950-learning`. Legacy prod already pulls from it: `web` uses
`artifacts.developer.gov.bc.ca/m950-learning/nginxinc/nginx-unprivileged:1-alpine-slim` (note: upstream moved to
`nginx/nginx-unprivileged`; the `nginxinc/` path stopped at 1.30.6 / 1.31.7 and gets no further fixes) and `redis-proxy` uses
`artifacts.developer.gov.bc.ca/m950-learning/redis-proxy@sha256:…`. 950003-tools also has 8 image streams (internal registry;
prod `php` and `cron` run `*-security-patch` images from there by digest). **Use the `m950-learning` Artifactory repository.**

### 0.8 Legacy automation
- Health monitor: `MANUAL_MODE=true` in dev and prod, **`false` in test** (deferred to E4, Q18). The only alert variable is
  `ROCKET_CHAT_WEBHOOK` (F8).
- Cron: a 1-replica Deployment in each namespace, using the image's default command.
- No HPAs (F5).
- GitHub: `build.yml` active; `scheduled-rebuild.yml` disabled on 2026-11-18; default branch `main`.

### 0.9 Moodle settings (prod; test differences in brackets)
- Auth: only `oauth2` enabled. Issuers: "BC Government Login" enabled (`loginproxy.gov.bc.ca`) [test:
  `test.loginproxy.gov.bc.ca`]; a second, **disabled** "Azure AD Login" issuer in prod.
- `local_psaelmsync` settings (the guard's override list): `apiurl`, `completion_apiurl` (prod `analytics-api.psa.gov.bc.ca`,
  test `analytics-testapi.psa.gov.bc.ca`), `apitoken`, `completion_apitoken`, `enabled`, `notificationemails`,
  `notificationhours`, `datefilterminutes`, `ignorecourseids`, `last_record_enrol_id`, `version` [test also `dashboardlink`].
- `local_githubsync` settings: `default_branch`, `version`, `webhook_secret` (empty).
- `local_*` scheduled tasks, all enabled: `local_githubsync\task\sync_courses`,
  `local_psaelmsync\task\process_course_completion`, `local_psaelmsync\task\sync_task`; all ran after 17:00 MST today.
- Web services: enabled, protocol `rest`; tokens as F6 [test: 5 mobile tokens, last used 2024-04-05].
- `moodle/site:maintenanceaccess`: no role overrides at system level; site admins only (F11).
- Database accounts: `moodle`, `monitor`, `root`, `mariabackup`, `mariadb.sys`. No reporting or integration accounts.
- `pathtogs=/usr/bin/gs`, `pathtounoconv=/usr/bin/unoconv` (F10).
- Automated course backups: prod active, stored in the course backup area. [Test: active, stored only in
  `/tmp/file-backups/courses`, a directory that **does not exist** on its `file-backup-data` volume, so test's automated
  course backups are probably failing.]
- Repositories: areafiles, contentbank, local, recent, upload, url, wikimedia [test also `user`].
- Mail: `smtphosts=apps.smtp.gov.bc.ca`, `smtpsecure` empty, `allowedemaildomains=*.gov.bc.ca`.
- Search: `simpledb`, global search on.
- Column types: prod's 26 binary-typed columns are in runbook §5.2; test has none (2 ASCII hash columns only).

### 0.10 Custom webroot scripts (Q8)
Prod php logs cover 2026-11-04 to 2026-11-18 (286,393 lines): **no requests** to `cdata-proxy.php`, `list_courses.php`,
`find-courses-with-tag.php`, `update-course-tag.php`, `migrate-courses`, `fix-mojibake*`,
`moodle_index_during_maintenance.php` or `redis-stats.php`. Test's logs cover only a day while in maintenance. The nginx
`web` pods log nothing.

### 0.11 Data sizes
| | Prod | Test |
|---|---|---|
| Database (data + index + free) | 486 + 488 + 189 MiB, 719 tables | 55 + 50 + 47 MiB, 713 tables |
| Galera PVCs | 5 × 10 GiB, **7.1 GiB free each** | 5 × 7 GiB, 5.1 GiB free each |
| moodledata PVC | 12 GiB RWX, 8.4 GiB used, 3.7 GiB free | 12 GiB RWX, 3.4 GiB used, 8.7 GiB free |
| `filedir` on disk | 9,326 files, 8.4 GiB | 7,342 files, 3.4 GiB |
| Referenced by `files` | 8,772 hashes, **2.93 GiB** | 7,241 hashes, **1.67 GiB** |
| Unreferenced on disk | 557 files, 5.25 GiB | 110 files, 1.56 GiB |
| Referenced but missing | 3 (one badge's images, 2021) | 9 (2021 user icons and backups; 2 H5P files, 2026-01) |
| Other top-level moodledata | `temp` 90 MiB, `localcache` 7 MiB | `temp` 23 MiB, `localcache` 15 MiB, `cache` 13 MiB |

Galera free space covers the §14 bail-out requirement (at least 2× the database) in both.
The unreferenced prod files are mostly 10–100 MiB each (202 files, 4.49 GiB). Their modification dates cluster in 2025-06
and 2026-05, the months of the two known database events. File timestamps reflect copies and restores, not uploads (983
*referenced* files also carry 2026-05 dates), so whether any of them is content that lost its database row in May cannot be
told from metadata alone (owner question O1).

### 0.12 Maintenance serving
`maintenance-message`: dev 1/1 running, with both dev Routes pointing at it; test has none (Moodle serves its own
maintenance page); prod has the Deployment at 0 replicas.

### 0.13 Routes
| Namespace | Route | Host | To | TLS | Certificate | Timeout |
|---|---|---|---|---|---|---|
| dev | `moodle-web` | `moodle-950003-dev.apps.silver.devops.gov.bc.ca` | `maintenance-message` | edge | router | 180 s |
| dev | `redis-insight` | `redis-insight-950003-dev.apps.silver.devops.gov.bc.ca` | `maintenance-message` | none | n/a | default |
| test | `moodle-web` | `moodle-950003-test.apps.silver.devops.gov.bc.ca` | `web` | edge | router | 180 s |
| prod | `moodle-custom` | `learning.gww.gov.bc.ca` | `web` | edge, HTTP→HTTPS redirect | **custom** | default (30 s) |
| prod | `moodle-web` | `moodle-950003-prod.apps.silver.devops.gov.bc.ca` | `web` | edge | router | 180 s |

All legacy Routes use `targetPort: 8080`. Q1 for test: its only hostname is the platform one; no custom domain.

## Questions answered

| Q | Answer |
|---|---|
| Q1 (test hostnames) | One Route, `moodle-950003-test.apps.silver.devops.gov.bc.ca`. Prod as §5.7. Certificate ownership for `learning.gww.gov.bc.ca` remains open |
| Q6 (other systems) | None found: only mobile-app tokens; no extra database accounts |
| Q8 (custom scripts) | Unused in two weeks of logs: do not carry them |
| Q13 (image home) | `artifacts.developer.gov.bc.ca/m950-learning`, already used by legacy prod's `web` and `redis-proxy` images |
| Q14 (alerts) | Today's legacy alerts go to Rocket.Chat, which is discontinued; a new channel is needed |

## New questions for the owner
- **O1.** Prod has 5.25 GiB of unreferenced files. Copy only referenced files (recommended; legacy keeps the rest until
  decommission)? Is it worth checking whether any of them are uploads that lost their database rows in May 2026?
- **O2.** GitHub sync's task still runs every night in prod and test. Disable it in legacy now (one approved change per
  environment), or leave it to the replatform?
- **O3.** Test's automated course backups point at a directory that does not exist. Fix now, or leave it to the replatform?
- **O4.** The prod trigger `trg_log_completion_criteria_delete` (logs deleted completion criteria into
  `course_completion_criteria_log`) was created on 2026-05-15, during the split-brain recovery. Is that audit still needed?
  `tool_dbtransfer` will not carry it to the new stack (second review, RB01).
