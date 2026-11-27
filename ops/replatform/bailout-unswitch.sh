#!/usr/bin/env bash
# Undo the handover (replatform runbook §14.6 undo, D3, V702 cleanup step 2). CHANGES THE CLUSTER. Dry run unless --apply.
#
#   TARGET=galera:<ns>/<galera pod> [RELEASE=psa-moodle] bailout-unswitch.sh <namespace> [--apply]
#
# 1. Restores, from the `prereturn` capture, every consumer's env (DB_NAME back to its Secret reference) and the backup
#    ConfigMap, using state-restore.sh; restarts the backup.
# 2. Proves php (every pod) and cron (probe pod) use `moodle` again.
# 3. REVOKEs the application account's privileges on moodle_bailout.* (only after step 2 passes).
# Routes, replicas and maintenance are NOT changed here; they belong to other steps.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
NS=${1:?namespace}
APPLY=0; [ "${2:-}" = "--apply" ] && APPLY=1
APP_USER=${APP_USER:-moodle}
. "$HERE/rp-mariadb-target.sh"
. "$HERE/which-db.sh"
CAP="$HOME/Moodle/private-backups/state-$NS-prereturn"
[ -d "$CAP" ] || { echo "no prereturn capture" >&2; exit 1; }

echo "== 1. env and backup target from the prereturn capture"
args=(); [ "$APPLY" -eq 1 ] && args+=(--apply)
# The release name makes state-restore skip the new stack's Helm-owned Deployments: without it, the fenced stack's env
# would go back to its unfenced values (Pass B run 2 dry run, 2026-11-27). ${args[@]+...}: bash 3.2 and an empty array.
RESTORE_SCOPE=env,configmaps "$HERE/state-restore.sh" "$NS" prereturn "${RELEASE:-psa-moodle}" ${args[@]+"${args[@]}"} || true
if [ "$APPLY" -eq 0 ]; then echo "dry run: nothing changed"; exit 0; fi
oc rollout restart -n "$NS" deploy/moodle-db-backup-storage
oc rollout status -n "$NS" deploy/php --timeout=600s

echo "== 2. prove php and cron use moodle"
bad=0
prove_php moodle || bad=1
prove_cron moodle || bad=1
[ "$bad" -eq 0 ] || { echo "NOT PROVEN: the grant stays until php and cron use moodle" >&2; exit 1; }

echo "== 3. revoke $APP_USER on moodle_bailout.*"
admin_sql -e "REVOKE ALL PRIVILEGES ON moodle_bailout.* FROM '$APP_USER'@'%'"
echo "unswitched and proven"
