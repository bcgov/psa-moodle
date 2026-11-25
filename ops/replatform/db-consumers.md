# Legacy database consumers (replatform runbook DR02, DR05, V506)

Everything in a legacy 950003 namespace that selects legacy's database. A return's handover (`bailout-switch.sh`) and its
undo (`bailout-unswitch.sh`) cover every row; a consumer with no proof fails the handover.

Read-only inventory of **950003-dev, 2026-11-25** (`oc get`). Re-run the inventory in each environment before its window,
because legacy objects differ between namespaces.

| Consumer | How it selects the database | Switched by | Proof |
|---|---|---|---|
| `deploy/php` | env `DB_NAME` from Secret `moodle-secrets` key `database-name` | `oc set env ... DB_NAME=moodle_bailout` | `which-db.php` in every pod |
| `deploy/cron` (kept at 0) | the same | the same | `which-db.php` in an `oc debug` probe pod from cron's own template |
| `deploy/pod-health-monitor` | the same (and it is at 0 or `MANUAL_MODE=true`, E4) | the same | its template's `DB_NAME` |
| `deploy/moodle-db-backup-storage` | ConfigMap `moodle-db-backup-storage-config`, key `backup-file`: `mariadb=mariadb-galera:3306/moodle` | `/moodle` → `/moodle_bailout`, then restart | the ConfigMap and the next verified backup |

Application account: `moodle` (Galera's `MARIADB_USER`). The return grants it `moodle_bailout.*` and revokes that grant on
undo.

Not consumers, checked: `web` (nginx, no database), `redis-proxy`, `maintenance-message`. Legacy dev also has leftover
Services from older deployments (`db`, `mysql`, `mysql-read`, `mariadb-101-rhel7`, `moodle-bitnami-mariadb`, `moodle`);
before each window, confirm none of them has endpoints serving Moodle.
