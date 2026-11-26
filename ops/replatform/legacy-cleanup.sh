#!/usr/bin/env bash
# Ordered legacy clean-up after an abandoned return (replatform runbook V702, V601, H3). CHANGES THE CLUSTER.
# Dry run unless --apply. Each step needs the previous one; a step that can't run stops it and every later step, and
# nothing is changed partially. Progress is kept in pending-cleanup.md; re-running resumes from the first step not done.
#
#   TARGET=galera:<ns>/<galera pod> legacy-cleanup.sh <namespace> [--apply]
#
#   1. maintenance and drain: legacy CLI maintenance (`maintenance.php --enable`), then wait until the application
#      account has NO connection on any Galera node, idle ones included, for 60 s and no legacy cron pod exists (V1006:
#      with dbpersist=0 a connection, even a sleeping one, is a request or cron run still in progress). Needs legacy
#      PHP and Galera.
# Resuming (V1006): when step 1 is already done, the drain is checked again (maintenance file present, 15 quiet
# seconds) before any later step runs.
#   2. switch back and prove it: bailout-unswitch.sh (DB_NAME, backup target, then REVOKE on moodle_bailout.*).
#   3. frozen checksums: frozen-checksums.sh compare against the prereturn record (taken AFTER the switch, V702).
#   4. remove the return's resources: drop the import account if any, then DROP DATABASE moodle_bailout.
# While anything is pending: no Route reaches legacy, legacy cron stays at 0, and legacy is not reopened or used as a
# return target or last resort (H3).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
NS=${1:?namespace}
APPLY=0; [ "${2:-}" = "--apply" ] && APPLY=1
APP_USER=${APP_USER:-moodle}
. "$HERE/rp-mariadb-target.sh"
DIR="$HOME/Moodle/private-backups/state-$NS-prereturn"
[ -d "$DIR" ] || { echo "no prereturn capture" >&2; exit 1; }
FROZEN=${FROZEN:-$HOME/Moodle/private-backups/frozen-checksums-$NS-prereturn.tsv}
PENDING="$HOME/Moodle/private-backups/pending-cleanup-$NS.md"
umask 077
[ -f "$PENDING" ] || printf '# Pending legacy clean-up: %s\n\nStarted %s. Legacy stays fenced until all four steps are done.\n\n' "$NS" "$(date -u +%FT%TZ)" > "$PENDING"
done_step() { grep -q "^- \[x\] step $1 " "$PENDING"; }
mark() { printf -- '- [x] step %s %s (%s)\n' "$1" "$2" "$(date -u +%FT%TZ)" >> "$PENDING"; }
stop() { printf -- '- [ ] step %s blocked: %s (%s)\n' "$1" "$2" "$(date -u +%FT%TZ)" >> "$PENDING"; echo "STOPPED at step $1: $2; later steps wait" >&2; exit 1; }
php_pod() { oc get pods -n "$NS" -l deployment=php --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }
# drain <step> <quiet seconds needed> <max 5-second polls>: no app connection on any node and no legacy cron pod.
drain() {
  local q=0 csel
  for _ in $(seq 1 "$3"); do
    busy=$(app_connections "$APP_USER") || stop "$1" "could not count connections on every Galera node"
    csel=$(oc get deploy cron -n "$NS" -o json | jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")')
    cron=$(oc get pods -n "$NS" -l "$csel" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$busy" = 0 ] && [ "$cron" = 0 ]; then q=$((q + 5)); else q=0; fi
    [ "$q" -ge "$2" ] && return 0
    sleep 5
  done
  return 1
}

if [ "$APPLY" -eq 0 ]; then
  echo "dry run. Steps done so far:"; grep '^- ' "$PENDING" || echo "  none"
  echo "legacy php pod: $(php_pod || echo none); galera: $(admin_sql -N -B -e 'SELECT 1' 2>/dev/null || echo unreachable)"
  exit 0
fi

# 1. Maintenance and drain.
if ! done_step 1; then
  pod=$(php_pod) || true
  [ -n "$pod" ] || stop 1 "no running legacy php pod"
  admin_sql -N -B -e 'SELECT 1' >/dev/null 2>&1 || stop 1 "Galera unreachable"
  oc exec -n "$NS" "$pod" -c php -- php /var/www/html/admin/cli/maintenance.php --enable || stop 1 "maintenance.php failed"
  drain 1 60 180 || stop 1 "legacy did not drain within 15 minutes (connections=$busy cron pods=$cron)"
  mark 1 "maintenance on, drained"
else
  # Resuming: prove again that nothing has started since (V1006).
  pod=$(php_pod) || true
  [ -n "$pod" ] || stop 2 "resuming: no running legacy php pod to check maintenance"
  oc exec -n "$NS" "$pod" -c php -- test -f /var/www/moodledata/climaintenance.html || stop 2 "resuming: legacy maintenance is off"
  drain 2 15 12 || stop 2 "resuming: legacy is not quiet (connections=$busy cron pods=$cron)"
fi

# 2. Switch back and prove it.
if ! done_step 2; then
  "$HERE/bailout-unswitch.sh" "$NS" --apply || stop 2 "bailout-unswitch.sh did not prove the switch back"
  mark 2 "consumers on moodle, proven; grant revoked"
fi

# 3. Frozen checksums, after the switch.
if ! done_step 3; then
  [ -f "$FROZEN" ] || stop 3 "no prereturn checksum record at $FROZEN"
  DB=moodle "$HERE/frozen-checksums.sh" compare "$FROZEN" || stop 3 "the frozen moodle differs from its prereturn record: investigate before anything else"
  mark 3 "frozen moodle matches its prereturn record"
fi

# 4. Remove the return's resources.
if ! done_step 4; then
  admin_sql <<'SQL' || stop 4 "could not drop the return's resources"
DROP USER IF EXISTS 'moodle_bailout_import'@'%';
DROP DATABASE IF EXISTS moodle_bailout;
SQL
  mark 4 "import account and moodle_bailout dropped"
fi
echo "clean-up complete; legacy may be considered again only by its own approval"
