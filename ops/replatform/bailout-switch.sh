#!/usr/bin/env bash
# Hand legacy over to `moodle_bailout` (replatform runbook §14.6, D3, DR01, DR02, DR05, V506). CHANGES THE CLUSTER.
# Dry run unless --apply. Requires the return's capture (state-capture.sh; CAPTURE, default `prereturn`) so
# bailout-unswitch.sh can undo it. Use the same CAPTURE for both scripts.
#
#   TARGET=galera:<ns>/<galera pod> bailout-switch.sh <namespace> [--apply]
#
# 1. GRANT the application account (default `moodle`) on moodle_bailout.*, then prove a php pod connects to
#    moodle_bailout with its own credentials, before anything switches.
# 2. DB_NAME=moodle_bailout on every env consumer in db-consumers.md (php, cron, pod-health-monitor); wait for php.
# 3. Prove each consumer: which-db.php in every php pod; cron (at 0) through a probe pod from its own template; the
#    health monitor's template. A consumer with no evidence fails the handover.
# 4. Retarget the database backup (moodle-db-backup-storage-config) to moodle_bailout and restart it.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
NS=${1:?namespace}
APPLY=0; [ "${2:-}" = "--apply" ] && APPLY=1
APP_USER=${APP_USER:-moodle}
ENV_CONSUMERS=${ENV_CONSUMERS:-"php cron pod-health-monitor"}
BACKUP_CM=${BACKUP_CM:-moodle-db-backup-storage-config}
. "$HERE/rp-mariadb-target.sh"
. "$HERE/which-db.sh"
CAPTURE=${CAPTURE:-prereturn}
[ -d "$HOME/Moodle/private-backups/state-$NS-$CAPTURE" ] || { echo "no $CAPTURE capture: run state-capture.sh $NS $CAPTURE first" >&2; exit 1; }
step() { echo "== $*"; }
run() { echo "   $(printf '%q ' "$@")"; if [ "$APPLY" -eq 1 ]; then "$@"; fi; }

step "1. grant $APP_USER on moodle_bailout.* and prove a php pod connects to it"
if [ "$APPLY" -eq 1 ]; then
  admin_sql -e "GRANT ALL PRIVILEGES ON moodle_bailout.* TO '$APP_USER'@'%'"
  oc exec -n "$NS" deploy/php -c php -- php -r '
    $m = @new mysqli(getenv("DB_HOST"), getenv("DB_USER"), getenv("DB_PASSWORD"), "moodle_bailout");
    if ($m->connect_errno) { fwrite(STDERR, "cannot connect to moodle_bailout: {$m->connect_error}\n"); exit(1); }
    $v = $m->query("SELECT value FROM config WHERE name = \"version\"")->fetch_row()[0];
    echo "   php connects to moodle_bailout as ", getenv("DB_USER"), ", version $v\n";'
else
  echo "   GRANT ALL PRIVILEGES ON moodle_bailout.* TO '$APP_USER'@'%'; then a mysqli connect from deploy/php"
fi

step "2. DB_NAME=moodle_bailout on: $ENV_CONSUMERS"
for d in $ENV_CONSUMERS; do run oc set env -n "$NS" "deploy/$d" DB_NAME=moodle_bailout; done
run oc rollout status -n "$NS" deploy/php --timeout=600s

step "3. prove every consumer"
if [ "$APPLY" -eq 1 ]; then
  bad=0
  prove_php moodle_bailout || bad=1
  prove_cron moodle_bailout || bad=1
  for d in $ENV_CONSUMERS; do
    v=$(oc get deploy "$d" -n "$NS" -o jsonpath='{.spec.template.spec.containers[*].env[?(@.name=="DB_NAME")].value}')
    echo "   $d template DB_NAME=$v"; [ "$v" = "moodle_bailout" ] || bad=1
  done
  [ "$bad" -eq 0 ] || { echo "HANDOVER NOT PROVEN: undo with bailout-unswitch.sh $NS --apply" >&2; exit 1; }
else
  echo "   which-db.php in every php pod; cron probe via oc debug; DB_NAME in each template"
fi

step "4. retarget the database backup ($BACKUP_CM) and restart it"
if [ "$APPLY" -eq 1 ]; then
  oc get configmap "$BACKUP_CM" -n "$NS" -o json \
    | jq '.data["backup-file"] |= sub("/moodle\n"; "/moodle_bailout\n")' | oc replace -f -
  oc get configmap "$BACKUP_CM" -n "$NS" -o jsonpath='{.data.backup-file}' | head -1 | sed 's/^/   backup target: /'
  oc rollout restart -n "$NS" deploy/moodle-db-backup-storage
else
  echo "   backup-file: mariadb=mariadb-galera:3306/moodle -> /moodle_bailout; oc rollout restart deploy/moodle-db-backup-storage"
fi
[ "$APPLY" -eq 1 ] && echo "handover done and proven" || echo "dry run: nothing changed"
