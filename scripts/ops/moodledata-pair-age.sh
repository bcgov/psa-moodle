#!/usr/bin/env bash
# moodledata-pair-age.sh (runbook J4; review V1011): how old is the newest USABLE recovery pair? Runs daily as its own
# CronJob, independent of the backup runs, so failing, skipped or missed runs are noticed even when no run gets far
# enough to report anything. Reads the backup volume (read-only) and the pgBackRest repository's backup labels.
#
# A set is usable when it is published, not FILES-ONLY (its database half expired), not DAMAGED, and its base backup
# label is still in the repository. Alerts:
#   newest usable pair older than ALERT_DAYS     ALERT to ALERT_TO
#   older than ESCALATE_DAYS, or none at all     ESCALATE to ALERT_TO and ESCALATE_TO (the owner)
#   the repository can't be read                 ALERT (pairing unknown)
set -euo pipefail
: "${DEST:=/backup}" "${ALERT_DAYS:=3}" "${ESCALATE_DAYS:=5}" "${ESCALATE_TO:=}"
: "${PGBACKREST_INFO_CMD:=oc -n ${TARGET_NAMESPACE:-} exec ${POSTGRES_CLUSTER:-}-repo-host-0 -c pgbackrest -- pgbackrest --output=json info}"
SETS="$DEST/sets"
log() { printf '%s [pair-age] %s\n' "$(date -u +%FT%TZ)" "$*"; }
send() {  # send <recipients> <subject> <body>
  log "ALERT: $2"
  command -v alert.sh >/dev/null && [ -n "$1" ] && ALERT_TO="$1" alert.sh "psa-moodle moodledata backup: $2" "$3" || true
}

if ! info=$(eval "$PGBACKREST_INFO_CMD" 2>/dev/null) || ! labels=$(jq -r '.[0].backup[]?.label' <<< "$info" 2>/dev/null); then
  send "${ALERT_TO:-}" "pair age unknown: the pgBackRest repository can't be read" "pgbackrest info failed; check the repo host."
  exit 1
fi

now=$(date -u +%s); usable=""; age=""
for s in $(ls -1 "$SETS" 2>/dev/null | sort -r); do
  [ -f "$SETS/$s/manifest.json" ] || continue
  [ -f "$SETS/$s/FILES-ONLY" ] && continue
  [ -f "$SETS/$s/DAMAGED" ] && continue
  b=$(jq -r '.database.base_backup // empty' "$SETS/$s/manifest.json")
  grep -qxF "$b" <<< "$labels" || continue
  ts=$(sed -E 's/^rp-set-([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})Z.*/\1-\2-\3T\4:\5:\6Z/' <<< "$s")
  age=$(( now - $(jq -rn --arg t "$ts" '$t | fromdateiso8601') ))
  usable=$s; break
done

both="${ALERT_TO:-}${ESCALATE_TO:+,$ESCALATE_TO}"
if [ -z "$usable" ]; then
  send "$both" "ESCALATE: no usable recovery pair" "No published set has both its files and its base backup. Look at the last backup runs' logs."
  exit 1
fi
days=$(( age / 86400 )); hours=$(( age / 3600 ))
if [ "$age" -gt $(( ESCALATE_DAYS * 86400 )) ]; then
  send "$both" "ESCALATE: newest usable recovery pair is $days days old ($usable)" "No usable set for over $ESCALATE_DAYS days (J4)."
  exit 1
elif [ "$age" -gt $(( ALERT_DAYS * 86400 )) ]; then
  send "${ALERT_TO:-}" "newest usable recovery pair is $days days old ($usable)" "No usable set for over $ALERT_DAYS days (J4)."
  exit 1
fi
log "newest usable pair: $usable, ${hours} h old"
