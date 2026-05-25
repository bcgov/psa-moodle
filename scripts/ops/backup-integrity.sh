#!/usr/bin/env bash
# backup-integrity.sh — Phase 6 daily backup-integrity check.
#
# This is the structural fix for the 2026-04 incident (sessions table missing
# from dumps, 20-byte gzip files going undetected). It runs three classes of
# check against the live Crunchy primary and its pgBackRest repo:
#
#   1. pgBackRest repo state — `pgbackrest info` shows recent backups exist
#      and are in "ok" status; `pgbackrest verify` walks archives for checksum
#      mismatches.
#   2. Content sanity — required Moodle tables exist in the live primary, and
#      canonical tables have non-zero row counts.
#   3. Recency — most recent full backup is within the expected window.
#
# Any failure: send email, exit non-zero. A non-zero exit fails the Job — the
# CronJob's failedJobsHistoryLimit retains it, and the existing Phase 5 build
# pipeline doesn't promote anything based on backup health, so there's nothing
# else to interlock.

set -euo pipefail

: "${POSTGRES_CLUSTER:?POSTGRES_CLUSTER not set}"
: "${POSTGRES_USER_SECRET:?POSTGRES_USER_SECRET not set}"
: "${TARGET_NAMESPACE:?TARGET_NAMESPACE not set}"
: "${MAX_FULL_BACKUP_AGE_HOURS:=30}"   # alert if no full backup in N hours

# Canonical Moodle tables: must exist in every healthy DB. This is exactly the
# list Warren flagged as missing from the April backups.
REQUIRED_TABLES=(
  mdl_user
  mdl_course
  mdl_sessions
  mdl_task_adhoc
  mdl_task_scheduled
  mdl_task_log
  mdl_config
)

# Tables that should always have rows in a real Moodle instance.
NONZERO_TABLES=(
  mdl_user
  mdl_config
  mdl_task_scheduled
)

log()  { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" ; }
fail() {
  log "FAIL: $*"
  /usr/local/bin/alert.sh \
    "psa-moodle [$TARGET_NAMESPACE]: backup integrity FAIL" \
    "$(date -u): $*

Recent log:
$(tail -80 "$LOGFILE" 2>/dev/null || echo "(no log)")

Inspect:
  oc -n $TARGET_NAMESPACE get cronjob psa-moodle-backup-integrity
  oc -n $TARGET_NAMESPACE logs -l job-name=\$(oc -n $TARGET_NAMESPACE get jobs -l app.kubernetes.io/component=backup-integrity --sort-by=.metadata.creationTimestamp -o name | tail -1 | cut -d/ -f2)
"
  exit 1
}

LOGFILE="$(mktemp)"
trap 'rm -f "$LOGFILE"' EXIT
exec > >(tee -a "$LOGFILE") 2>&1

log "Phase 6 backup-integrity check starting (cluster=$POSTGRES_CLUSTER, ns=$TARGET_NAMESPACE)"

# --- DB connection params from the Crunchy-managed pguser Secret ---------------
DB_HOST="$(oc -n "$TARGET_NAMESPACE" get secret "$POSTGRES_USER_SECRET" -o jsonpath='{.data.host}'     | base64 -d)"
DB_PORT="$(oc -n "$TARGET_NAMESPACE" get secret "$POSTGRES_USER_SECRET" -o jsonpath='{.data.port}'     | base64 -d)"
DB_NAME="$(oc -n "$TARGET_NAMESPACE" get secret "$POSTGRES_USER_SECRET" -o jsonpath='{.data.dbname}'   | base64 -d)"
DB_USER="$(oc -n "$TARGET_NAMESPACE" get secret "$POSTGRES_USER_SECRET" -o jsonpath='{.data.user}'     | base64 -d)"
export PGPASSWORD
PGPASSWORD="$(oc -n "$TARGET_NAMESPACE" get secret "$POSTGRES_USER_SECRET" -o jsonpath='{.data.password}' | base64 -d)"

psql_q() { psql -X -A -t -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "$1" ; }

# --- 1. pgBackRest state -------------------------------------------------------
# pgBackRest runs inside the Crunchy repo-host pod; we exec there to query it.
REPO_POD="$(oc -n "$TARGET_NAMESPACE" get pod -l "postgres-operator.crunchydata.com/cluster=$POSTGRES_CLUSTER,postgres-operator.crunchydata.com/pgbackrest=" -o name | head -1)"
[ -n "$REPO_POD" ] || fail "no pgBackRest pod found for cluster $POSTGRES_CLUSTER"

log "Reading pgbackrest info from $REPO_POD"
PGB_INFO_JSON="$(oc -n "$TARGET_NAMESPACE" exec "$REPO_POD" -c pgbackrest -- pgbackrest --output=json info)"

# Most recent successful "full" backup timestamp (epoch).
LAST_FULL_EPOCH="$(echo "$PGB_INFO_JSON" | jq -r \
  '[ .[0].backup[] | select(.type=="full") | .timestamp.stop ] | max // 0')"
NOW_EPOCH="$(date -u +%s)"
AGE_HOURS=$(( (NOW_EPOCH - LAST_FULL_EPOCH) / 3600 ))

if [ "$LAST_FULL_EPOCH" -eq 0 ]; then
  fail "pgBackRest reports zero successful full backups"
fi
log "Last full backup completed ${AGE_HOURS}h ago"
if [ "$AGE_HOURS" -gt "$MAX_FULL_BACKUP_AGE_HOURS" ]; then
  fail "last full backup is ${AGE_HOURS}h old (threshold ${MAX_FULL_BACKUP_AGE_HOURS}h)"
fi

# Any backup in non-ok status?
NOT_OK="$(echo "$PGB_INFO_JSON" | jq -r '.[0].backup[] | select(.error == true or .annotation.ok == "false") | .label')"
if [ -n "$NOT_OK" ]; then
  fail "pgBackRest reports non-ok backups: $NOT_OK"
fi

log "Running pgbackrest verify (this walks archives — can take a few minutes)"
if ! oc -n "$TARGET_NAMESPACE" exec "$REPO_POD" -c pgbackrest -- pgbackrest --stanza=db verify ; then
  fail "pgbackrest verify reported checksum mismatch — repo is corrupted"
fi

# --- 2. Content sanity in the live primary -------------------------------------
log "Checking required tables exist"
for t in "${REQUIRED_TABLES[@]}"; do
  exists="$(psql_q "SELECT to_regclass('public.$t') IS NOT NULL")"
  if [ "$exists" != "t" ]; then
    fail "required table missing in live primary: $t"
  fi
done

log "Checking canonical tables are non-empty"
for t in "${NONZERO_TABLES[@]}"; do
  n="$(psql_q "SELECT count(*) FROM $t")"
  if [ "${n:-0}" -lt 1 ]; then
    fail "canonical table $t has 0 rows in live primary"
  fi
  log "  $t: $n rows"
done

log "OK: pgBackRest repo healthy, last full ${AGE_HOURS}h ago, required tables present, canonical tables non-empty"

# Quiet on success — emailing every success would just train people to ignore
# the channel. Job-completion stamping is via Kubernetes Job history.
