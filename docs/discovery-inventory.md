# Discovery Inventory: current production state

Fill this in once. The data here feeds **Phase 6** (backup sizing), **Phase 7** (migration rehearsal), and **Phase 8** (cutover runbook). Most of it requires `oc` access to the existing production namespace.

> **Note:** This file may eventually contain sensitive sizing/operational data. If so, move the populated copy to a secure location and replace this one with a sanitized version before committing.

---

## 1. Moodle application

| Item | Value | How to find |
|---|---|---|
| Current Moodle version | `_____` | Production Moodle → Site administration → Notifications, or `cat config.php` |
| PHP version in prod | `_____` | `oc -n <prod-ns> exec deploy/php -- php -v` |
| Configured DB driver | `mariadb` (expected) | `config.php` → `$CFG->dbtype` |
| Site root URL | `_____` | `config.php` → `$CFG->wwwroot` |
| Maintenance mode currently active? | yes/no | Site admin → Server → Maintenance |

## 2. Plugins installed (confirm vs the new build)

Already approved for the new build:

- [x] `block_course_search`
- [x] `local_githubsync` (or similar — confirm component name)
- [x] `local_pathcurator` (confirm)
- [x] `local_psaelmsync` (confirm)
- [x] `mod_hvp`
- [x] `auth_oidc` (for CSS integration)
- [x] `theme_bcgovpsa`

**Anything in current prod NOT in the list above:**

```
oc -n <prod-ns> exec deploy/php -- php /var/www/html/admin/cli/plugin_list.php > prod-plugins.txt
```

Paste any plugin codes that appear in `prod-plugins.txt` but are not in the approved list. For each, decide: **carry forward / drop / replace**.

| Plugin code | Version | Decision | Reason |
|---|---|---|---|
| _____ | _____ | _____ | _____ |

## 3. Themes

| Theme | Decision |
|---|---|
| `theme_bcgovpsa` | carry forward (already in build) |
| Parent theme (likely `boost`) | core, no action |
| Anything else in `theme/`? | confirm none |

## 4. Database (MariaDB Galera, current prod)

```sh
# Approximate uncompressed size:
oc -n <prod-ns> exec mariadb-galera-0 -- \
  mysql -uroot -p<root-pw> -e \
  "SELECT SUM(data_length+index_length)/1024/1024 AS size_mb FROM information_schema.tables WHERE table_schema='moodle';"

# Per-table top 10:
oc -n <prod-ns> exec mariadb-galera-0 -- \
  mysql -uroot -p<root-pw> -e \
  "SELECT table_name, ROUND((data_length+index_length)/1024/1024,1) AS mb FROM information_schema.tables WHERE table_schema='moodle' ORDER BY mb DESC LIMIT 10;"
```

| Item | Value |
|---|---|
| Total DB size (MB) | `_____` |
| Largest table | `_____` (mb: `_____`) |
| Charset / collation in use | `_____` (`SHOW VARIABLES LIKE 'character_set_database';`) |
| Notable non-default config | `_____` |

This number sizes the Postgres PVC, the pgBackRest repo PVC, and the maintenance window for `pgloader` in Phase 7.

## 5. `moodledata` shared volume

```sh
oc -n <prod-ns> exec deploy/php -- du -sh /var/www/moodledata
oc -n <prod-ns> exec deploy/php -- du -sh /var/www/moodledata/filedir
oc -n <prod-ns> exec deploy/php -- du -sh /var/www/moodledata/temp
oc -n <prod-ns> exec deploy/php -- du -sh /var/www/moodledata/cache
```

| Path | Size |
|---|---|
| `/var/www/moodledata` total | `_____` |
| `filedir/` (user uploads — must migrate) | `_____` |
| `temp/`, `cache/`, `trashdir/` (do NOT need to migrate) | `_____` |

Migration sizing is **`filedir/` + `repository/` only.** The rest gets regenerated.

## 6. Integrations to re-configure in the new environment

For each, capture endpoint + credential storage location. Do **not** paste credentials into this file.

| Integration | Endpoint | Credential location | Status |
|---|---|---|---|
| LDAP/SAML/OIDC IdP | CSS via OIDC (planned) | TBD (filed via sso-requests.apps.gold) | not yet requested |
| SMTP relay | `_____` | `_____` | `_____` |
| Filesystem backups (S3?) | n/a — moved to in-cluster PVC | n/a | new plan |
| External course catalogue / LMS sync | `_____` | `_____` | `_____` |
| Reverse-proxy / WAF in front | OpenShift Route + (whatever sits in front today) | `_____` | `_____` |
| Sysdig | cluster-wide agent | n/a | inherited |

## 7. OpenShift cluster facts

```sh
oc version
oc get clusterversion
oc get crd | grep -E 'postgrescluster|certificate|sealedsecrets'
oc get storageclass
oc -n <prod-ns> get route -o jsonpath='{.items[*].spec.host}{"\n"}'
```

| Item | Value |
|---|---|
| OCP version | `_____` |
| Crunchy operator version | `_____` |
| RWX storage class | `netapp-file-standard` (expected) |
| Default block storage class | `_____` |
| sealed-secrets operator present? | yes/no |
| cert-manager / Route TLS approach | `_____` |

## 8. Resource sizing — current prod requests/limits

Snapshot the existing production sizing so the new Helm chart's `values-test.yaml` starts at the same order of magnitude (not as a target — as a sanity ceiling).

```sh
oc -n <prod-ns> get pods -l app=moodle -o \
  custom-columns=NAME:.metadata.name,CPU_REQ:.spec.containers[*].resources.requests.cpu,MEM_REQ:.spec.containers[*].resources.requests.memory,CPU_LIM:.spec.containers[*].resources.limits.cpu,MEM_LIM:.spec.containers[*].resources.limits.memory
```

| Workload | Replicas | CPU req | Mem req | CPU lim | Mem lim |
|---|---|---|---|---|---|
| `web` (nginx) | `_____` | `_____` | `_____` | `_____` | `_____` |
| `php` (php-fpm) | `_____` | `_____` | `_____` | `_____` | `_____` |
| `cron` | `_____` | `_____` | `_____` | `_____` | `_____` |
| `mariadb-galera` (per node) | `_____` | `_____` | `_____` | `_____` | `_____` |
| `redis` (per node) | `_____` | `_____` | `_____` | `_____` | `_____` |
| `redis-proxy` (per node) | `_____` | `_____` | `_____` | `_____` | `_____` |

## 9. Open questions to resolve before Phase 7

- [ ] H5P content (used by HVP plugin) — migrate to core `mod_h5pactivity`, or keep `mod_hvp`?
- [ ] Are there any custom user fields / cohorts / roles configured outside of plugins that need manual recreation?
- [ ] Are there any scheduled tasks with non-default frequencies?
- [ ] Email digest, notification templates — anything customized that lives in DB rather than code?

---

## Completion criterion

When every numbered section above has at least the headline values populated, Phase 0 discovery is done and Phase 7 (data migration rehearsal) can be designed against real numbers.
